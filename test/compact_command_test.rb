# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/borgator'

# /compact: one toolless turn summarizes the conversation, and the summary
# becomes the new conversation so the session can keep going.
class CompactCommandTest < Minitest::Test
  # Records what the summarizing turn was given, and answers with a canned
  # summary instead of calling an API.
  class FakeProvider
    attr_reader :seen_messages, :seen_system, :seen_tools, :context_window

    def initialize(summary: 'HANDOVER: rewrote the drain buffer in lib/input_drain.rb.',
                   context_window: 200_000)
      @summary = summary
      @context_window = context_window
    end

    def label = 'anthropic'
    def model_label = 'claude-opus-4-8'
    def message_shape = :anthropic

    def agent_run(messages, events, system:, tools:, depth:)
      @seen_messages = messages
      @seen_system = system
      @seen_tools = tools
      @seen_depth = depth
      events << { kind: :assistant, text: @summary, depth: 0 } unless @summary.nil?
      @summary
    end
  end

  # Stands in for opencode, which owns its history server-side.
  class ServerSideProvider
    def label = 'opencode'
    def model_label = 'anthropic/claude-opus-4-8'
    def message_shape = :opencode
  end

  def setup
    @provider = FakeProvider.new
    @app = AgentApp.new(@provider)
    converse('add a retry helper', 'done — see lib/retry.rb')
  end

  def converse(*turns)
    messages = @app.instance_variable_get(:@messages)
    turns.each_slice(2) do |user, assistant|
      messages << { 'role' => 'user', 'content' => user }
      messages << { 'role' => 'assistant', 'content' => assistant } if assistant
    end
  end

  def messages = @app.instance_variable_get(:@messages)

  def log_text
    @app.instance_variable_get(:@log).map { |e| e[:text].to_s }.join("\n")
  end

  def compact(arg = nil)
    Commands.run('/compact', @app, arg)
    @app.instance_variable_get(:@worker_thread)&.join
    @app.send(:drain_events)
  end

  def test_compact_is_a_registered_command
    assert(Commands::ALL.any? { |cmd| cmd[:name] == '/compact' })
  end

  def test_conversation_is_replaced_by_its_summary
    compact

    assert_equal 1, messages.length
    assert_equal 'user', messages.first['role']
    assert_match(/HANDOVER: rewrote the drain buffer/, messages.first['content'])
    assert_match(/re-read any file before\s+changing it/, messages.first['content'])
    assert_match(/Compacted/, log_text)
  end

  # The summarizing turn must not be able to touch anything.
  def test_the_summarizing_turn_gets_no_tools
    compact

    assert_empty @provider.seen_tools
    assert_match(/compacting a coding session/i, @provider.seen_system)
  end

  def test_the_summarizer_sees_the_history_plus_an_instruction
    compact

    contents = @provider.seen_messages.map { |m| m['content'] }
    assert_includes contents, 'add a retry helper'
    assert_match(/Compact this conversation now/, contents.last)
  end

  def test_focus_is_passed_to_the_summarizer
    compact('keep the sandbox findings')

    assert_match(/keep the sandbox findings/, @provider.seen_messages.last['content'])
  end

  def test_an_empty_summary_leaves_the_conversation_alone
    app = AgentApp.new(FakeProvider.new(summary: '  '))
    app.instance_variable_get(:@messages) << { 'role' => 'user', 'content' => 'hi' }
    Commands.run('/compact', app)
    app.instance_variable_get(:@worker_thread)&.join
    app.send(:drain_events)

    assert_equal 1, app.instance_variable_get(:@messages).length
    assert_equal 'hi', app.instance_variable_get(:@messages).first['content']
    assert_match(/produced no summary/, app.instance_variable_get(:@log).map { |e| e[:text] }.join("\n"))
  end

  def test_refused_mid_turn
    @app.instance_variable_set(:@thinking, true)
    Commands.run('/compact', @app)

    assert_match(/a turn is running/, log_text)
    assert_equal 2, messages.length
  end

  def test_refused_when_the_conversation_is_empty
    app = AgentApp.new(FakeProvider.new)
    Commands.run('/compact', app)

    assert_match(/Nothing to compact/, app.instance_variable_get(:@log).map { |e| e[:text] }.join("\n"))
  end

  def test_refused_for_a_provider_that_owns_its_own_history
    app = AgentApp.new(ServerSideProvider.new)
    app.instance_variable_get(:@messages) << { 'role' => 'user', 'content' => 'hi' }
    Commands.run('/compact', app)

    assert_match(/manages its own conversation history/,
                 app.instance_variable_get(:@log).map { |e| e[:text] }.join("\n"))
  end

  def test_context_meter_follows_the_smaller_conversation
    converse('a' * 40_000, 'b' * 40_000)
    before = @app.send(:display_context_tokens)
    compact
    assert_operator @app.send(:display_context_tokens), :<, before
  end

  def test_a_full_context_is_flagged_once
    app = AgentApp.new(FakeProvider.new(context_window: 1_000))
    app.instance_variable_set(:@context_tokens, 900)

    app.send(:maybe_hint_compaction)
    app.send(:maybe_hint_compaction)
    hints = app.instance_variable_get(:@log).count { |e| e[:text].to_s.include?('/compact summarizes') }
    assert_equal 1, hints
  end

  def test_no_hint_below_the_threshold
    app = AgentApp.new(FakeProvider.new(context_window: 1_000_000))
    app.instance_variable_set(:@context_tokens, 10)

    app.send(:maybe_hint_compaction)
    refute_match(%r{/compact summarizes}, app.instance_variable_get(:@log).map { |e| e[:text] }.join("\n"))
  end
end
