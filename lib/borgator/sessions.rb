# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'time'

require_relative 'sandbox'

# Persisted chat sessions, so quitting doesn't throw the conversation away.
#
# A session is saved after every completed turn to
# `~/.borgator/sessions/<project>/<id>.json`, holding the provider-shaped
# message array the loop feeds back to the model plus a trimmed copy of the
# chat log for redisplay. `/resume` lists this project's recent sessions and
# reloads one.
#
# Sessions are scoped to the project directory they ran in — the conversation
# is about *these* files — and to the provider's wire format: Anthropic
# content blocks and OpenAI tool_calls are not interchangeable, so a session is
# only offered to a provider that speaks the same shape.
module Sessions
  DEFAULT_DIR = '~/.borgator/sessions'

  # Sessions kept per project; older files are pruned oldest-first.
  MAX_PER_PROJECT = 30

  # Log entries kept for redisplay, and the cap on each one's text.
  MAX_LOG_ENTRIES = 400
  MAX_LOG_TEXT = 4_000

  MAX_TITLE_CHARS = 70

  FORMAT = 1

  # Kinds worth restoring to the screen. Permission prompts and progress noise
  # describe a moment that has passed.
  LOG_KINDS = %i[user assistant tool tool_result error worker_start worker_done].freeze

  module_function

  # Id for a fresh session, sortable by creation time.
  def new_id
    "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{format('%04x', rand(0x10000))}"
  end

  # Wire format of a provider's messages, so a session is only ever resumed
  # into a provider that can send it back.
  def shape_of(provider)
    return nil unless provider.respond_to?(:message_shape)

    provider.message_shape.to_s
  end

  # Where sessions are stored. BORGATOR_SESSIONS_DIR relocates them (tests set
  # it; so can anyone who keeps transcripts elsewhere).
  def dir
    File.expand_path(ENV.fetch('BORGATOR_SESSIONS_DIR', DEFAULT_DIR))
  end

  # One directory per project, keyed by path so two checkouts with the same
  # basename don't share a history.
  def project_dir(root = Sandbox.root)
    slug = File.basename(root.to_s).gsub(/[^A-Za-z0-9._-]/, '-')
    slug = 'project' if slug.empty?
    File.join(dir, "#{slug}-#{Digest::SHA256.hexdigest(root.to_s)[0, 8]}")
  end

  def path_for(id, root = Sandbox.root)
    File.join(project_dir(root), "#{id}.json")
  end

  # Write the session, replacing any earlier save of the same id. Returns the
  # path, or nil when there is nothing worth saving or the write fails —
  # persistence is a convenience and must never take a turn down with it.
  def save(id:, provider:, messages:, log:, root: Sandbox.root)
    return nil if id.nil? || messages.nil? || messages.empty?

    path = path_for(id, root)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(record(id, provider, messages, log, root)))
    prune!(root)
    path
  rescue StandardError
    nil
  end

  # This project's saved sessions, newest first. Pass a shape to list only the
  # ones the current provider could actually resume.
  def recent(shape: nil, root: Sandbox.root, limit: MAX_PER_PROJECT)
    entries = Dir.glob(File.join(project_dir(root), '*.json')).filter_map { |path| summary(path) }
    entries = entries.select { |entry| entry[:shape] == shape.to_s } if shape
    # Id breaks ties, so two saves in the same instant still order stably.
    entries.sort_by { |entry| [entry[:updated_at].to_s, entry[:id].to_s] }.reverse.first(limit)
  rescue StandardError
    []
  end

  # Full session by id, or nil when it is missing or unreadable.
  def load(id, root: Sandbox.root)
    data = read(path_for(id, root))
    return nil unless data

    {
      id: data['id'],
      provider: data['provider'],
      model: data['model'],
      shape: data['shape'],
      title: data['title'],
      messages: data['messages'] || [],
      log: symbolize_log(data['log'])
    }
  end

  def delete(id, root: Sandbox.root)
    File.delete(path_for(id, root))
    true
  rescue StandardError
    false
  end

  # Drop the oldest sessions past MAX_PER_PROJECT. Ids start with a timestamp,
  # so the glob's sorted order is oldest-first.
  def prune!(root = Sandbox.root)
    files = Dir.glob(File.join(project_dir(root), '*.json'))
    return if files.length <= MAX_PER_PROJECT

    files.first(files.length - MAX_PER_PROJECT).each do |path|
      File.delete(path)
    rescue StandardError
      nil
    end
  end

  # Human-readable age, e.g. "2h ago".
  def age(time)
    seconds = (Time.now - time).to_i
    return 'just now' if seconds < 60
    return "#{seconds / 60}m ago" if seconds < 3_600
    return "#{seconds / 3_600}h ago" if seconds < 86_400

    "#{seconds / 86_400}d ago"
  rescue StandardError
    ''
  end

  # --- internals ----------------------------------------------------------

  def record(id, provider, messages, log, root)
    now = Time.now
    {
      'format' => FORMAT,
      'id' => id,
      'cwd' => root.to_s,
      'provider' => provider.respond_to?(:label) ? provider.label : nil,
      'model' => provider.respond_to?(:model_label) ? provider.model_label : nil,
      'shape' => shape_of(provider),
      'title' => title_from(messages),
      # Sub-second precision: two turns can easily complete in the same second,
      # and /resume orders by this.
      'created_at' => (created_at(id, root) || now).iso8601(6),
      'updated_at' => now.iso8601(6),
      'messages' => messages,
      'log' => trimmed_log(log)
    }
  end

  # Keep the original creation stamp across re-saves of the same session.
  def created_at(id, root)
    data = read(path_for(id, root))
    Time.parse(data['created_at'])
  rescue StandardError
    nil
  end

  def summary(path)
    data = read(path)
    return nil unless data && data['id']

    {
      id: data['id'],
      provider: data['provider'],
      model: data['model'],
      shape: data['shape'],
      title: data['title'].to_s,
      turns: Array(data['messages']).count { |msg| msg['role'] == 'user' },
      updated_at: data['updated_at'].to_s
    }
  end

  def read(path)
    return nil unless File.file?(path)

    data = JSON.parse(File.read(path))
    data.is_a?(Hash) && data['format'] == FORMAT ? data : nil
  rescue StandardError
    nil
  end

  # First thing the user actually asked, which is what they recognise a session
  # by. Tool results and content blocks are skipped.
  def title_from(messages)
    text = messages.find { |msg| msg['role'] == 'user' && msg['content'].is_a?(String) }&.fetch('content')
    text = text.to_s.strip.split("\n").find { |line| !line.strip.empty? }.to_s.strip
    return '(untitled)' if text.empty?
    return text if text.length <= MAX_TITLE_CHARS

    "#{text[0, MAX_TITLE_CHARS - 1]}…"
  end

  def trimmed_log(log)
    Array(log).last(MAX_LOG_ENTRIES).filter_map do |entry|
      next unless LOG_KINDS.include?(entry[:kind])

      text = entry[:text].to_s
      text = "#{text[0, MAX_LOG_TEXT]}…" if text.length > MAX_LOG_TEXT
      { 'kind' => entry[:kind].to_s, 'text' => text, 'depth' => entry[:depth].to_i }
    end
  end

  def symbolize_log(log)
    Array(log).filter_map do |entry|
      kind = entry['kind'].to_s.to_sym
      next unless LOG_KINDS.include?(kind)

      { kind: kind, text: entry['text'].to_s, depth: entry['depth'].to_i }
    end
  end
end
