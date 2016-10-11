# encoding: utf-8
# author: Dominik Richter
# author: Christoph Hartmann

require 'rspec/core'
require 'rspec/core/formatters/json_formatter'

# Vanilla RSpec JSON formatter with a slight extension to show example IDs.
# TODO: Remove these lines when RSpec includes the ID natively
class InspecRspecVanilla < RSpec::Core::Formatters::JsonFormatter
  RSpec::Core::Formatters.register self

  private

  # We are cheating and overriding a private method in RSpec's core JsonFormatter.
  # This is to avoid having to repeat this id functionality in both dump_summary
  # and dump_profile (both of which call format_example).
  # See https://github.com/rspec/rspec-core/blob/master/lib/rspec/core/formatters/json_formatter.rb
  #
  # rspec's example id here corresponds to an inspec test's control name -
  # either explicitly specified or auto-generated by rspec itself.
  def format_example(example)
    res = super(example)
    res[:id] = example.metadata[:id]
    res
  end
end

# Minimal JSON formatter for inspec. Only contains limited information about
# examples without any extras.
class InspecRspecMiniJson < RSpec::Core::Formatters::JsonFormatter
  # Don't re-register all the call-backs over and over - we automatically
  # inherit all callbacks registered by the parent class.
  RSpec::Core::Formatters.register self, :dump_summary, :stop

  # Called after stop has been called and the run is complete.
  def dump_summary(summary)
    @output_hash[:version] = Inspec::VERSION
    @output_hash[:statistics] = {
      duration: summary.duration,
    }
  end

  # Called at the end of a complete RSpec run.
  def stop(notification)
    # This might be a bit confusing. The results are not actually organized
    # by control. It is organized by test. So if a control has 3 tests, the
    # output will have 3 control entries, each one with the same control id
    # and different test results. An rspec example maps to an inspec test.
    @output_hash[:controls] = notification.examples.map do |example|
      format_example(example).tap do |hash|
        e = example.exception
        next unless e
        hash[:message] = e.message

        next if e.is_a? RSpec::Expectations::ExpectationNotMetError
        hash[:exception] = e.class.name
        hash[:backtrace] = e.backtrace
      end
    end
  end

  private

  def format_example(example)
    if example.metadata[:description_args].length > 0 && !example.metadata[:skip].nil?
      # For skipped profiles, rspec returns in full_description the skip_message as well. We don't want
      # to mix the two, so we pick the full_description from the example.metadata[:example_group] hash.
      code_description = example.metadata[:example_group][:description]
    else
      code_description = example.metadata[:full_description]
    end

    res = {
      id: example.metadata[:id],
      status: example.execution_result.status.to_s,
      code_desc: code_description,
    }

    unless (pid = example.metadata[:profile_id]).nil?
      res[:profile_id] = pid
    end

    if res[:status] == 'pending'
      res[:status] = 'skipped'
      res[:skip_message] = example.metadata[:description]
      res[:resource] = example.metadata[:described_class].to_s
    end

    res
  end
end

class InspecRspecJson < InspecRspecMiniJson # rubocop:disable Metrics/ClassLength
  RSpec::Core::Formatters.register self, :start, :stop, :dump_summary
  attr_writer :backend

  def initialize(*args)
    super(*args)
    @profiles = []
    # Will be valid after "start" state is reached.
    @profiles_info = nil
    @backend = nil
  end

  # Called by the runner during example collection.
  def add_profile(profile)
    @profiles.push(profile)
  end

  # Called after all examples have been collected but before rspec
  # test execution has begun.
  def start(_notification)
    # Note that the default profile may have no name - therefore
    # the hash may have a valid nil => entry.
    @profiles_info = @profiles.map(&:info!).map(&:dup)
  end

  def dump_one_example(example, control)
    control[:results] ||= []
    example.delete(:id)
    example.delete(:profile_id)
    control[:results].push(example)
  end

  def stop(notification)
    super(notification)
    examples = @output_hash.delete(:controls)
    missing = []

    examples.each do |example|
      control = example2control(example, @profiles_info)
      next missing.push(example) if control.nil?
      dump_one_example(example, control)
    end

    @output_hash[:profiles] = @profiles_info
    @output_hash[:other_checks] = missing
  end

  def controls_summary
    failed = 0
    skipped = 0
    passed = 0
    critical = 0
    major = 0
    minor = 0

    @control_tests.each do |control|
      next if control[:id].start_with? '(generated from '
      next unless control[:results]
      if control[:results].any? { |r| r[:status] == 'failed' }
        failed += 1
        if control[:impact] >= 0.7
          critical += 1
        elsif control[:impact] >= 0.4
          major += 1
        else
          minor += 1
        end
      elsif control[:results].any? { |r| r[:status] == 'skipped' }
        skipped += 1
      else
        passed += 1
      end
    end

    total = failed + passed + skipped

    { 'total' => total,
      'failed' => {
        'total' => failed,
        'critical' => critical,
        'major' => major,
        'minor' => minor,
      },
      'skipped' => skipped,
      'passed' => passed }
  end

  def tests_summary
    total = 0
    failed = 0
    skipped = 0
    passed = 0

    all_tests = @anonymous_tests + @control_tests
    all_tests.each do |control|
      next unless control[:results]
      control[:results].each do |result|
        if result[:status] == 'failed'
          failed += 1
        elsif result[:status] == 'skipped'
          skipped += 1
        else
          passed += 1
        end
      end
    end

    { 'total' => total, 'failed' => failed, 'skipped' => skipped, 'passed' => passed }
  end

  private

  #
  # TODO(ssd+vj): We should probably solve this by either ensuring the example has
  # the profile_id of the top level profile when it is included as a dependency, or
  # by registrying all dependent profiles with the formatter. The we could remove
  # this heuristic matching.
  #
  def example2profile(example, profiles)
    profiles.find { |p| profile_contains_example?(p, example) }
  end

  def profile_contains_example?(profile, example)
    # Heuristic for finding the profile an example came from:
    # Case 1: The profile_id on the example matches the name of the profile
    # Case 2: The profile contains a control that matches the id of the example
    if profile[:name] == example[:profile_id]
      true
    elsif profile[:controls] && profile[:controls].any? { |x| x[:id] == example[:id] }
      true
    else
      false
    end
  end

  def example2control(example, profiles)
    profile = example2profile(example, profiles)
    return nil unless profile && profile[:controls]
    profile[:controls].find { |x| x[:id] == example[:id] }
  end

  def format_example(example)
    super(example).tap do |res|
      res[:run_time]   = example.execution_result.run_time
      res[:start_time] = example.execution_result.started_at.to_s
    end
  end
end

class InspecRspecCli < InspecRspecJson # rubocop:disable Metrics/ClassLength
  RSpec::Core::Formatters.register self, :close

  STATUS_TYPES = {
    'unknown'  => -3,
    'passed'   => -2,
    'skipped'  => -1,
    'minor'    => 1,
    'major'    => 2,
    'failed'   => 2.5,
    'critical' => 3,
  }.freeze

  COLORS = {
    'critical' => "\033[31;1m",
    'major'    => "\033[31m",
    'minor'    => "\033[33m",
    'failed'   => "\033[31m",
    'passed'   => "\033[32m",
    'skipped'  => "\033[37m",
    'reset'    => "\033[0m",
  }.freeze

  INDICATORS = {
    'critical' => '  ✖  ',
    'major'    => '  ✖  ',
    'minor'    => '  ✖  ',
    'failed'   => '  ✖  ',
    'skipped'  => '  ○  ',
    'passed'   => '  ✔  ',
    'unknown'  => '  ?  ',
    'empty'    => '     ',
    'small'    => '   ',
  }.freeze

  MULTI_TEST_CONTROL_SUMMARY_MAX_LEN = 60

  def initialize(*args)
    @colors = COLORS
    @indicators = INDICATORS

    @format = '%color%indicator%id%summary'
    @current_control = nil
    @current_profile = nil
    @missing_controls = []
    @anonymous_tests = []
    @control_tests = []
    @profile_printed = false
    super(*args)
  end

  def close(_notification) # rubocop:disable Metrics/AbcSize
    flush_current_control
    output.puts('') unless @current_control.nil?
    print_tests
    output.puts('')

    print_profiles_info if !@profile_printed
    controls_res = controls_summary
    tests_res = tests_summary

    s = format('Profile Summary: %s%d successful%s, %s%d failures%s, %s%d skipped%s',
               COLORS['passed'], controls_res['passed'], COLORS['reset'],
               COLORS['failed'], controls_res['failed']['total'], COLORS['reset'],
               COLORS['skipped'], controls_res['skipped'], COLORS['reset'])
    output.puts(s) if controls_res['total'] > 0

    s = format('Test Summary: %s%d successful%s, %s%d failures%s, %s%d skipped%s',
               COLORS['passed'], tests_res['passed'], COLORS['reset'],
               COLORS['failed'], tests_res['failed'], COLORS['reset'],
               COLORS['skipped'], tests_res['skipped'], COLORS['reset'])
    output.puts(s) if !@anonymous_tests.empty? || @current_control.nil?
  end

  private

  def status_type(data, control)
    status = data[:status]
    return status if status != 'failed' || control[:impact].nil?
    if control[:impact] >= 0.7
      'critical'
    elsif control[:impact] >= 0.4
      'major'
    else
      'minor'
    end
  end

  def current_control_infos
    summary_status = STATUS_TYPES['unknown']
    skips = []
    fails = []
    passes = []
    @current_control[:results].each do |r|
      i = STATUS_TYPES[r[:status_type]]
      summary_status = i if i > summary_status
      fails.push(r) if i > 0
      passes.push(r) if i == STATUS_TYPES['passed']
      skips.push(r) if i == STATUS_TYPES['skipped']
    end
    [fails, skips, passes, STATUS_TYPES.key(summary_status)]
  end

  def current_control_title
    title = @current_control[:title]
    res = @current_control[:results]
    if title
      title
    elsif res.length == 1
      # If it's an anonymous control, just go with the only description
      # available for the underlying test.
      res[0][:code_desc].to_s
    elsif res.length == 0
      # Empty control block - if it's anonymous, there's nothing we can do.
      # Is this case even possible?
      'Empty anonymous control'
    else
      # Multiple tests - but no title. Do our best and generate some form of
      # identifier or label or name.
      title = (res.map { |r| r[:code_desc] }).join('; ')
      max_len = MULTI_TEST_CONTROL_SUMMARY_MAX_LEN
      title = title[0..(max_len-1)] + '...' if title.length > max_len
      title
    end
  end

  def current_control_summary(fails, skips)
    title = current_control_title
    res = @current_control[:results]
    suffix =
      if res.length == 1
        # Single test - be nice and just print the exception message if the test
        # failed. No need to say "1 failed".
        res[0][:message].to_s
      else
        [
          (fails.length > 0) ? "#{fails.length} failed" : nil,
          (skips.length > 0) ? "#{skips.length} skipped" : nil,
        ].compact.join(' ')
      end
    if suffix == ''
      title
    else
      title + ' (' + suffix + ')'
    end
  end

  def format_line(fields)
    @format.gsub(/%\w+/) do |x|
      term = x[1..-1]
      fields.key?(term.to_sym) ? fields[term.to_sym].to_s : x
    end + @colors['reset']
  end

  def print_line(fields)
    output.puts(format_line(fields))
  end

  def format_lines(lines, indentation)
    lines.gsub(/\n/, "\n" + indentation)
  end

  def print_results(all)
    all.each do |x|
      test_status = x[:status_type]
      test_color = @colors[test_status]
      indicator = @indicators[x[:status]]
      indicator = @indicators['empty'] if indicator.nil?
      if x[:message]
        msg = x[:code_desc] + "\n" + x[:message]
      else
        msg = x[:skip_message] || x[:code_desc]
      end
      print_line(
        color:      test_color,
        indicator:  @indicators['small'] + indicator,
        summary:    format_lines(msg, @indicators['empty']),
        id: nil, profile: nil
      )
    end
  end

  def print_tests # rubocop:disable Metrics/AbcSize
    @anonymous_tests.each do |control|
      control_result = control[:results]
      title = control_result[0][:code_desc].split[0..1].join(' ')
      puts '  ' + title
      # iterate over all describe blocks in anonoymous control block
      control_result.each do |test|
        control_id = ''
        # display exceptions
        unless test[:exception].nil?
          test_result = test[:message]
        else
          # determine title
          test_result = test[:skip_message] || test[:code_desc].split[2..-1].join(' ')
          # show error message
          test_result += "\n" + test[:message] unless test[:message].nil?
        end
        status_indicator = test[:status_type]
        print_line(
          color:      @colors[status_indicator] || '',
          indicator:  @indicators['small'] + @indicators[status_indicator] || @indicators['unknown'],
          summary:    format_lines(test_result, @indicators['empty']),
          id:         control_id,
          profile:    control[:profile_id],
        )
      end
    end
  end

  def flush_current_control
    return if @current_control.nil?

    @current_profile = @profiles_info.find { |i| i[:id] == @current_control[:profile_id] }
    print_current_profile if !@profile_printed

    fails, skips, passes, summary_indicator = current_control_infos
    summary = current_control_summary(fails, skips)

    control_id = @current_control[:id].to_s
    control_id += ': '
    if control_id.start_with? '(generated from '
      @anonymous_tests.push(@current_control)
    else
      @control_tests.push(@current_control)
      print_line(
        color:      @colors[summary_indicator] || '',
        indicator:  @indicators[summary_indicator] || @indicators['unknown'],
        summary:    format_lines(summary, @indicators['empty']),
        id:         control_id,
        profile:    @current_control[:profile_id],
      )

      print_results(fails + skips + passes)
    end
  end

  def print_target(before, after)
    return if @backend.nil?
    connection = @backend.backend
    return unless connection.respond_to?(:uri)
    output.puts(before + connection.uri + after)
  end

  def print_profiles_info
    @profiles_info.each do |profile|
      next if profile[:already_printed]
      @current_profile = profile
      next unless print_current_profile
      print_line(
        color: '', indicator: @indicators['empty'], id: '', profile: '',
        summary: 'No tests executed.'
      ) if @current_control.nil?
      output.puts('')
    end
  end

  def print_current_profile
    profile = @current_profile
    if profile.nil?
      print_profiles_info
      @profile_printed = true
      return true
    end
    output.puts ''
    profile[:already_printed] = true

    if profile[:name].nil?
      print_target('Target:  ', "\n\n")
      @profile_printed = true
      return true
    end

    if profile[:title].nil?
      output.puts "Profile: #{profile[:name] || 'unknown'}"
    else
      output.puts "Profile: #{profile[:title]} (#{profile[:name] || 'unknown'})"
    end

    output.puts 'Version: ' + (profile[:version] || 'unknown')
    print_target('Target:  ', "\n")
    output.puts
    @profile_printed = true
    true
  end

  def format_example(example)
    data = super(example)
    control = example2control(data, @profiles_info) || {}
    control[:id] = data[:id]
    control[:profile_id] = data[:profile_id]

    data[:status_type] = status_type(data, control)
    dump_one_example(data, control)

    @current_control ||= control
    if control[:id].nil?
      @missing_controls.push(data)
    elsif @current_control[:id] != control[:id]
      flush_current_control
      @current_control = control
    end

    data
  end
end
