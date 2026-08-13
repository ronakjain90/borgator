# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/borgator/pricing'

# Session spend: priced from published per-million rates, with cache rates
# derived from the input rate, and silence rather than guesses for the rest.
class PricingTest < Minitest::Test
  def usage(input: 0, output: 0, cache_read: 0, cache_write: 0)
    { input: input, output: output, cache_read: cache_read, cache_write: cache_write }
  end

  def with_overrides(json)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'pricing.json')
      File.write(path, json)
      ENV['BORGATOR_PRICING_FILE'] = path
      yield
    ensure
      ENV.delete('BORGATOR_PRICING_FILE')
    end
  end

  def test_overrides_add_rates_for_unknown_models
    with_overrides('{"openai": {"gpt-4o": {"input": 2.5, "output": 10}}}') do
      assert_in_delta 2.5, Pricing.for('openai', 'gpt-4o')[:input]
      assert_in_delta 0.25, Pricing.for('openai', 'gpt-4o')[:cache_read]
      assert_in_delta 12.5, Pricing.cost(usage(input: 1_000_000, output: 1_000_000),
                                         provider: 'openai', model: 'gpt-4o')
    end
  end

  def test_overrides_win_per_model_and_leave_the_rest_built_in
    with_overrides('{"anthropic": {"claude-opus-4-8": {"input": 1, "output": 2}}}') do
      assert_in_delta 1.0, Pricing.for('anthropic', 'claude-opus-4-8')[:input]
      assert_in_delta 1.0, Pricing.for('anthropic', 'claude-haiku-4-5')[:input]
    end
  end

  def test_explicit_cache_rates_override_the_derived_ones
    with_overrides('{"openai": {"gpt-4o": {"input": 2.5, "output": 10, "cache_read": 1.25}}}') do
      assert_in_delta 1.25, Pricing.for('openai', 'gpt-4o')[:cache_read]
      assert_in_delta 3.125, Pricing.for('openai', 'gpt-4o')[:cache_write]
    end
  end

  # A malformed file must not take pricing down with it.
  def test_a_broken_overrides_file_falls_back_to_built_ins
    with_overrides('{not json') do
      assert_in_delta 5.0, Pricing.for('anthropic', 'claude-opus-4-8')[:input]
      assert_nil Pricing.for('openai', 'gpt-4o')
    end
  end

  def test_known_model_rates
    rates = Pricing.for('anthropic', 'claude-opus-4-8')
    assert_in_delta 5.0, rates[:input]
    assert_in_delta 25.0, rates[:output]
  end

  # Cache rates follow the input rate: reads 0.1x, writes 1.25x.
  def test_cache_rates_derive_from_input
    rates = Pricing.for('anthropic', 'claude-opus-4-8')
    assert_in_delta 0.5, rates[:cache_read]
    assert_in_delta 6.25, rates[:cache_write]
  end

  def test_cost_sums_every_token_class
    amount = Pricing.cost(usage(input: 1_000_000, output: 1_000_000, cache_read: 1_000_000,
                                cache_write: 1_000_000),
                          provider: 'anthropic', model: 'claude-opus-4-8')
    assert_in_delta(5.0 + 25.0 + 0.5 + 6.25, amount)
  end

  def test_dated_and_namespaced_ids_price_against_their_model
    assert_equal Pricing.for('anthropic', 'claude-opus-4-8'),
                 Pricing.for('anthropic', 'claude-opus-4-8-20260101')
    assert_equal Pricing.for('anthropic', 'claude-sonnet-5'),
                 Pricing.for('anthropic', 'anthropic/claude-sonnet-5')
  end

  # Longest prefix wins, so a shorter id never shadows a more specific one.
  def test_longest_prefix_wins
    assert_in_delta 1.0, Pricing.for('anthropic', 'claude-haiku-4-5-20251001')[:input]
  end

  def test_unknown_models_are_not_guessed
    assert_nil Pricing.for('anthropic', 'claude-something-unreleased')
    assert_nil Pricing.for('openai', 'gpt-4o')
    assert_nil Pricing.cost(usage(input: 10_000), provider: 'openai', model: 'gpt-4o')
  end

  def test_local_providers_are_free
    assert_equal 0.0, Pricing.cost(usage(input: 5_000_000, output: 1_000_000),
                                   provider: 'ollama', model: 'llama3.1')
  end

  def test_total_across_models_reports_what_it_could_not_price
    buckets = {
      %w[anthropic claude-opus-4-8] => usage(input: 1_000_000),
      %w[openai gpt-4o] => usage(input: 1_000_000)
    }
    total, unpriced = Pricing.total(buckets)
    assert_in_delta 5.0, total
    assert_equal 1, unpriced
  end

  def test_total_is_nil_when_nothing_can_be_priced
    total, unpriced = Pricing.total({ %w[openai gpt-4o] => usage(input: 1_000) })
    assert_nil total
    assert_equal 1, unpriced
  end

  # A model that was configured but never used shouldn't be reported as
  # something we failed to price.
  def test_unused_models_are_not_counted_as_unpriced
    total, unpriced = Pricing.total({ %w[openai gpt-4o] => usage })
    assert_nil total
    assert_equal 0, unpriced
  end

  def test_formatting_rounds_and_flags_sub_cent_amounts
    assert_equal '$1.23', Pricing.format_usd(1.2345)
    assert_equal '$0.00', Pricing.format_usd(0.0)
    assert_equal '<$0.01', Pricing.format_usd(0.0004)
    assert_nil Pricing.format_usd(nil)
  end
end
