# frozen_string_literal: true

module Buildkite
  module TestCollector
  end
end

# Got concurrent-ruby dependency from ActiveSupport
require "concurrent/utility/monotonic_time"
require "json"
require "logger"
require "net/http"
require "openssl"
require "time"
require "timeout"
require "tmpdir"
require "securerandom"
require "socket"
require "websocket"

require "active_support/core_ext/object/blank"
require "active_support/core_ext/hash/indifferent_access"
require "active_support/notifications"

require_relative "test_collector/version"
require_relative "test_collector/error"
require_relative "test_collector/logger"
require_relative "test_collector/ci"
require_relative "test_collector/http_client"
require_relative "test_collector/uploader"
require_relative "test_collector/network"
require_relative "test_collector/object"
require_relative "test_collector/tracer"
require_relative "test_collector/socket_connection"
require_relative "test_collector/session"

module Buildkite
  module TestCollector
    DEFAULT_URL = "https://analytics-api.buildkite.com/v1/uploads"

    class << self
      attr_accessor :api_token
      attr_accessor :url
      attr_accessor :uploader
      attr_accessor :session
      attr_accessor :debug_enabled
      attr_accessor :tracing_enabled
    end

    def self.configure(hook:, token: nil, url: nil, debug_enabled: false, tracing_enabled: true)
      self.api_token = (token || ENV["BUILDKITE_ANALYTICS_TOKEN"])&.strip
      self.url = url || DEFAULT_URL
      self.debug_enabled = debug_enabled || !!(ENV["BUILDKITE_ANALYTICS_DEBUG_ENABLED"])
      self.tracing_enabled = tracing_enabled

      self.hook_into(hook)
    end

    def self.hook_into(hook)
      file = "test_collector/library_hooks/#{hook}"
      require_relative file
    rescue LoadError
      raise ArgumentError.new("#{hook.inspect} is not a supported Buildkite Analytics Test library hook.")
    end

    def self.annotate(content)
      tracer = Buildkite::TestCollector::Uploader.tracer
      tracer&.enter("annotation", **{ content: content })
      tracer&.leave
    end

    def self.log_formatter
      @log_formatter ||= Buildkite::TestCollector::Logger::Formatter.new
    end

    def self.log_formatter=(log_formatter)
      @log_formatter = log_formatter
      logger.formatter = log_formatter
    end

    def self.logger=(logger)
      @logger = logger
    end

    def self.logger
      return @logger if defined?(@logger)

      debug_mode = ENV.fetch("BUILDKITE_ANALYTICS_DEBUG_ENABLED") do
        $DEBUG
      end

      level = !!debug_mode ? ::Logger::DEBUG : ::Logger::WARN
      @logger ||= Buildkite::TestCollector::Logger.new($stderr, level: level)
    end

    def self.enable_tracing!
      return unless self.tracing_enabled

      Buildkite::TestCollector::Network.configure
      Buildkite::TestCollector::Object.configure

      ActiveSupport::Notifications.subscribe("sql.active_record") do |name, start, finish, id, payload|
        Buildkite::TestCollector::Uploader.tracer&.backfill(:sql, finish - start, **{ query: payload[:sql] })
      end
    end
  end
end
