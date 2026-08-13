# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/borgator'

# /cost attributes spend to the model that produced it, so a manager on Opus
# and workers on a cheaper model are priced apart.
class CostCommandTest < Minitest::Test
  class FakeProvider
    def initialize(label = 'anthropic', model = 'claude-opus-4-8')
      @label = label
      @model = model
    end

    attr_reader :label

    def model_label = @model
    def message_shape = :anthropic
  end

  def setup
    @app = AgentApp.new(FakeProvider.new)
  end

  def log_text
    @app.instance_variable_get(:@log).map { |e| e[:text].to_s }.join("\n")
  end

  def spend(provider:, model:, input: 0, output: 0, cache_read: 0, cache_write: 0)
    @app.send(:record_usage,
              { kind: :usage, provider: provider, model: model,
                usage: { input: input, output: output,
                         cache_read: cache_read, cache_write: cache_write } })
  end

  def test_cost_is_a_registered_command
    assert(Commands::ALL.any? { |cmd| cmd[:name] == '/cost' })
  end

  def test_no_usage_yet
    Commands.run('/cost', @app)
    assert_match(/No usage yet/, log_text)
  end

  def test_totals_and_per_model_breakdown
    spend(provider: 'anthropic', model: 'claude-opus-4-8', input: 1_000_000, output: 200_000)
    spend(provider: 'anthropic', model: 'claude-haiku-4-5', input: 1_000_000, output: 200_000)

    Commands.run('/cost', @app)

    # Opus: $5 in + $5 out = $10.00. Haiku: $1 in + $1 out = $2.00.
    assert_match(/Session cost — \$12\.00 estimated/, log_text)
    assert_match(/claude-opus-4-8.*\$10\.00/, log_text)
    assert_match(/claude-haiku-4-5.*\$2\.00/, log_text)
  end

  # Most expensive first — that's the line the user is looking for.
  def test_rows_are_ordered_by_spend
    spend(provider: 'anthropic', model: 'claude-haiku-4-5', input: 1_000_000)
    spend(provider: 'anthropic', model: 'claude-opus-4-8', input: 1_000_000)

    Commands.run('/cost', @app)
    rows = log_text.lines.select { |line| line.include?('claude-') }
    assert_match(/claude-opus-4-8/, rows.first)
    assert_match(/claude-haiku-4-5/, rows.last)
  end

  def test_unpriced_models_are_reported_not_guessed
    spend(provider: 'anthropic', model: 'claude-opus-4-8', input: 1_000_000)
    spend(provider: 'openai', model: 'gpt-4o', input: 1_000_000)

    Commands.run('/cost', @app)

    assert_match(/\$5\.00 estimated, plus 1 model with no known rate/, log_text)
    assert_match(/gpt-4o.*rate unknown/, log_text)
  end

  def test_usage_without_a_model_falls_back_to_the_current_provider
    @app.send(:record_usage, { kind: :usage, usage: { input: 1_000_000, output: 0 } })

    Commands.run('/cost', @app)
    assert_match(/claude-opus-4-8/, log_text)
    assert_match(/\$5\.00/, log_text)
  end

  def test_session_totals_still_accumulate_across_models
    spend(provider: 'anthropic', model: 'claude-opus-4-8', input: 10, output: 3)
    spend(provider: 'anthropic', model: 'claude-haiku-4-5', input: 5, output: 1)

    usage = @app.instance_variable_get(:@usage)
    assert_equal 15, usage[:input]
    assert_equal 4, usage[:output]
  end

  def test_status_bar_label
    assert_nil @app.send(:session_cost_label)
    spend(provider: 'anthropic', model: 'claude-opus-4-8', input: 200_000)
    assert_equal '$1.00', @app.send(:session_cost_label)
  end
end
