# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/borgator'

# Plan mode: the agent investigates and proposes, and cannot change anything —
# enforced at the tool list, the tool call, and the shell.
class PlanModeTest < Minitest::Test
  class FakeProvider
    def label = 'anthropic'
    def model_label = 'claude-opus-4-8'
    def message_shape = :anthropic
  end

  def setup
    PlanMode.disable!
    @app = AgentApp.new(FakeProvider.new)
  end

  def teardown
    PlanMode.disable!
    Sandbox.instance_variable_set(:@root, nil)
  end

  def in_project
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        Sandbox.instance_variable_set(:@root, File.realpath(dir))
        yield dir
      end
    end
  end

  def log_text
    @app.instance_variable_get(:@log).map { |e| e[:text].to_s }.join("\n")
  end

  # Swaps the persisted command allowlist without touching the user's real
  # preferences file.
  def with_persisted_allowlist(list)
    original = Preferences.method(:allowed_commands)
    Preferences.define_singleton_method(:allowed_commands) { list }
    yield
  ensure
    Preferences.define_singleton_method(:allowed_commands, original)
  end

  def tool_names(depth = 0)
    Agents.tools_for(depth).map { |tool| tool[:name].to_s }
  end

  def test_plan_is_a_registered_command
    assert(Commands::ALL.any? { |cmd| cmd[:name] == '/plan' })
  end

  def test_toggling_on_and_off
    Commands.run('/plan', @app)
    assert_predicate PlanMode, :active?
    assert_match(/Plan mode on/, log_text)

    Commands.run('/plan', @app)
    refute_predicate PlanMode, :active?
    assert_match(/Plan mode off/, log_text)
  end

  def test_explicit_on_and_off_are_idempotent
    Commands.run('/plan', @app, 'on')
    Commands.run('/plan', @app, 'on')
    assert_predicate PlanMode, :active?
    assert_match(/Already in plan mode/, log_text)

    Commands.run('/plan', @app, 'off')
    refute_predicate PlanMode, :active?
  end

  def test_unknown_argument_leaves_the_mode_alone
    Commands.run('/plan', @app, 'sideways')
    refute_predicate PlanMode, :active?
    assert_match(/unknown argument/, log_text)
  end

  def test_toggling_is_refused_mid_turn
    @app.instance_variable_set(:@thinking, true)
    Commands.run('/plan', @app)

    refute_predicate PlanMode, :active?
    assert_match(/a turn is running/, log_text)
  end

  # 1: the writing tools aren't offered to the model...
  def test_writing_tools_are_withheld_from_the_tool_list
    normal = tool_names
    assert_includes normal, 'write_file'
    assert_includes normal, 'edit_file'

    PlanMode.enable!
    planning = tool_names
    refute_includes planning, 'write_file'
    refute_includes planning, 'edit_file'
    assert_includes planning, 'read_file'
    assert_includes planning, 'search_code'
  end

  def test_workers_are_planning_too
    PlanMode.enable!
    refute_includes tool_names(1), 'write_file'
    assert_includes Agents.system_for(1), 'PLAN MODE IS ACTIVE'
    assert_includes Agents.system_for(0), 'PLAN MODE IS ACTIVE'
  end

  def test_system_prompt_is_untouched_in_normal_mode
    refute_includes Agents.system_for(0), 'PLAN MODE'
    refute_includes Agents.system_for(1), 'PLAN MODE'
  end

  # 2: ...and calling one anyway still changes nothing.
  def test_a_write_called_anyway_is_refused
    in_project do
      File.write('a.rb', "before\n")
      PlanMode.enable!

      summary, result = Tools.call('write_file', 'path' => 'a.rb', 'content' => "after\n")
      assert_match(/plan mode/, summary)
      assert_match(/Refused/, result)
      assert_equal "before\n", File.read('a.rb')

      _, edit_result = Tools.call('edit_file', 'path' => 'a.rb', 'old_string' => 'before',
                                               'new_string' => 'after')
      assert_match(/Refused/, edit_result)
      assert_equal "before\n", File.read('a.rb')
    end
  end

  def test_reading_tools_still_work
    in_project do
      File.write('a.rb', "hello\n")
      PlanMode.enable!

      _, result = Tools.call('read_file', 'path' => 'a.rb')
      assert_match(/hello/, result)
    end
  end

  # 3: the shell isn't a way around the first two.
  def test_only_read_only_commands_run
    PlanMode.enable!
    summary, result = Tools::RunCommand.run('rm -rf tmp')

    assert_match(/plan mode/, summary)
    assert_match(/only read-only commands/, result)
  end

  def test_read_only_git_commands_still_run
    assert_nil PlanMode.command_refusal('git status')
    PlanMode.enable!
    assert_nil PlanMode.command_refusal('git status')
    assert_nil PlanMode.command_refusal('git log --oneline -5')
  end

  # A command the user once approved permanently may still write; permission
  # and plan mode are different questions.
  def test_persisted_approvals_do_not_open_the_shell_in_plan_mode
    with_persisted_allowlist(['npm install']) do
      assert Tools.auto_allowed?('npm install'), 'expected the persisted prefix to skip prompts'
      PlanMode.enable!
      refute_nil PlanMode.command_refusal('npm install')
    end
  end

  # run_tests bypasses the permission prompt; it must not bypass plan mode.
  def test_run_tests_cannot_shell_out_while_planning
    PlanMode.enable!
    summary, = Tools::RunCommand.run('bundle exec rake test', skip_permission: true)
    assert_match(/plan mode/, summary)
  end

  def test_badge_shows_only_while_planning
    assert_nil @app.send(:plan_mode_badge)
    PlanMode.enable!
    assert_match(/plan/, @app.send(:plan_mode_badge))
  end
end
