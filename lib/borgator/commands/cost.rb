# frozen_string_literal: true

require_relative '../pricing'
require_relative '../usage'

module Commands
  # The /cost command: what this session has spent, per model.
  # Mixed into AgentApp, so it works on the app's state (@usage_by_model, @log).
  #
  # Usage events carry the model that produced them, so a manager on Opus and
  # workers on Haiku are priced separately rather than lumped together.
  module Cost
    def handle_cost
      if @usage_by_model.empty?
        @log << { kind: :assistant, text: 'No usage yet this session.' }
        return [self, nil]
      end

      total, unpriced = Pricing.total(@usage_by_model)
      @log << { kind: :assistant, text: cost_headline(total, unpriced) }
      cost_rows.each { |row| @log << { kind: :tool_result, text: row } }
      @log << { kind: :tool_result, text: '  estimated from published rates — check your provider for billing' }
      [self, nil]
    end

    # Record a usage event against the model that produced it. Older providers
    # (or replayed events) may not name one; those fall back to the manager.
    def record_usage(event)
      usage = event[:usage]
      return unless usage

      Usage.add!(@usage, usage)
      key = [event[:provider] || @provider&.label, event[:model] || @provider&.model_label]
      Usage.add!(@usage_by_model[key] ||= Usage.blank, usage)
    end

    # "$0.42" for the status bar, or nil when nothing priceable has been spent.
    def session_cost_label
      return nil if @usage_by_model.empty?

      total, = Pricing.total(@usage_by_model)
      Pricing.format_usd(total)
    end

    private

    def cost_headline(total, unpriced)
      return 'Session cost — no rates known for the models used (see ~/.borgator/pricing.json)' if total.nil?

      text = "Session cost — #{Pricing.format_usd(total)} estimated"
      text += ", plus #{unpriced} model#{'s' if unpriced != 1} with no known rate" if unpriced.positive?
      text
    end

    # One line per model, most expensive first; unpriced models sort last.
    def cost_rows
      priced = @usage_by_model.map do |(provider, model), usage|
        amount = Pricing.cost(usage, provider: provider, model: model)
        [amount, "  #{provider} · #{model}  —  #{Usage.format(usage) || 'no tokens'}  —  #{cost_cell(amount)}"]
      end

      priced.sort_by { |amount, _row| -(amount || -1) }.map { |_amount, row| row }
    end

    def cost_cell(amount)
      return 'rate unknown' if amount.nil?

      Pricing.format_usd(amount)
    end
  end
end
