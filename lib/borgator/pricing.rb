# frozen_string_literal: true

require 'json'

require_relative 'usage'

# What a session costs, in dollars.
#
# Rates are USD per million tokens. Cache rates are derived from the input rate
# rather than listed per model: a cache read bills at 0.1x input, a cache write
# at 1.25x (the 5-minute TTL, which is what an agent loop uses).
#
# Only rates we can state accurately are built in. Everything else reports
# "rate unknown" rather than inventing a number — a wrong cost is worse than no
# cost. Add or correct any model through ~/.borgator/pricing.json:
#
#   { "openai": { "gpt-4o": { "input": 2.5, "output": 10 } } }
#
# Overrides merge over the built-ins and may also set "cache_read" /
# "cache_write" explicitly when a provider doesn't follow the multipliers.
module Pricing
  DEFAULT_PATH = '~/.borgator/pricing.json'

  CACHE_READ_MULTIPLIER = 0.1
  CACHE_WRITE_MULTIPLIER = 1.25

  # USD per million tokens.
  RATES = {
    'anthropic' => {
      'claude-fable-5' => { input: 10.0, output: 50.0 },
      'claude-mythos-5' => { input: 10.0, output: 50.0 },
      'claude-opus-5' => { input: 5.0, output: 25.0 },
      'claude-opus-4-8' => { input: 5.0,  output: 25.0 },
      'claude-opus-4-7' => { input: 5.0,  output: 25.0 },
      'claude-opus-4-6' => { input: 5.0,  output: 25.0 },
      'claude-sonnet-5' => { input: 3.0,  output: 15.0 },
      'claude-sonnet-4-6' => { input: 3.0, output: 15.0 },
      'claude-haiku-4-5' => { input: 1.0, output: 5.0 }
    }.freeze,
    # Runs on the user's own machine — the tokens are free.
    'ollama' => :free
  }.freeze

  module_function

  # Rates for one provider+model, or nil when we don't know them.
  #
  # @return [Hash, nil] +{ input:, output:, cache_read:, cache_write:, free: }+
  def for(provider, model)
    table = table_for(provider)
    return nil unless table
    return zero_rates if table == :free

    entry = lookup(table, model.to_s)
    entry && expand(entry)
  end

  # Session cost in USD for one usage total, or nil when the model has no rates.
  def cost(usage, provider:, model:)
    rates = self.for(provider, model)
    return nil unless rates && usage

    ((usage[:input].to_i * rates[:input]) +
     (usage[:output].to_i * rates[:output]) +
     (usage[:cache_read].to_i * rates[:cache_read]) +
     (usage[:cache_write].to_i * rates[:cache_write])) / 1_000_000.0
  end

  # Total across per-model usage buckets: [total_usd, unpriced_model_count].
  # A session that mixes a priced manager with an unpriced worker reports the
  # part it can price and says how many models it couldn't.
  def total(buckets)
    total = 0.0
    unpriced = 0
    priced = false

    buckets.each do |(provider, model), usage|
      amount = cost(usage, provider: provider, model: model)
      if amount.nil?
        unpriced += 1 if Usage.any?(usage)
      else
        total += amount
        priced = true
      end
    end

    [priced ? total : nil, unpriced]
  end

  # "$1.23", or "<$0.01" for a non-zero amount that would round to nothing.
  def format_usd(amount)
    return nil if amount.nil?
    return '$0.00' if amount.zero?
    return '<$0.01' if amount < 0.005

    Kernel.format('$%.2f', amount)
  end

  # --- internals ----------------------------------------------------------

  # Built-in rates, with any user override layered on top per model.
  def table_for(provider)
    key = provider.to_s
    builtin = RATES[key]
    override = overrides[key]

    return builtin if override.nil?
    return override if builtin.nil? || builtin == :free

    builtin.merge(override)
  end

  # Exact id first, then the longest matching prefix, so dated or namespaced
  # variants ("claude-opus-4-8-20260101", "anthropic/claude-opus-4-8") still
  # price against the model they are.
  def lookup(table, model)
    id = model.to_s.strip
    id = id.split('/').last.to_s unless id.empty?
    return table[id] if table.key?(id)

    match = table.keys.select { |key| id.start_with?(key) }.max_by(&:length)
    match && table[match]
  end

  def expand(entry)
    input = rate(entry, :input)
    {
      input: input,
      output: rate(entry, :output),
      cache_read: rate(entry, :cache_read) || (input * CACHE_READ_MULTIPLIER),
      cache_write: rate(entry, :cache_write) || (input * CACHE_WRITE_MULTIPLIER),
      free: false
    }
  end

  def rate(entry, key)
    value = entry[key] || entry[key.to_s]
    value&.to_f
  end

  def zero_rates
    { input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, free: true }
  end

  # Where rate overrides live; BORGATOR_PRICING_FILE relocates them.
  def path
    File.expand_path(ENV.fetch('BORGATOR_PRICING_FILE', DEFAULT_PATH))
  end

  # User rate overrides, read fresh so edits apply without a restart.
  def overrides
    return {} unless File.file?(path)

    data = JSON.parse(File.read(path))
    return {} unless data.is_a?(Hash)

    data.each_with_object({}) do |(provider, models), out|
      next unless models.is_a?(Hash)

      out[provider.to_s] = models.each_with_object({}) do |(model, rates), inner|
        inner[model.to_s] = rates if rates.is_a?(Hash)
      end
    end
    # Narrow on purpose: a malformed or unreadable file falls back to the
    # built-in rates, but a bug in here must still surface.
  rescue JSON::ParserError, SystemCallError, IOError
    {}
  end
end
