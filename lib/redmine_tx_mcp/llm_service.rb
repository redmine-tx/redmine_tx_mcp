# frozen_string_literal: true

require 'net/http'
require 'json'
require 'digest'

module RedmineTxMcp
  class LlmService
    CLAUDE_API_URL = 'https://api.anthropic.com/v1/messages'
    DEFAULT_MODEL = 'claude-sonnet-4-6'
    CACHE_PREFIX = 'llm_service'
    CACHE_EXPIRES_IN = 1.day

    class << self
      # Check if the LLM service is available (API key configured)
      def available?
        api_key.present?
      end

      # Single-shot summarization — no tool use, no conversation history.
      # Results are cached by content hash: same input → cached response, no API call.
      #
      # @param prompt [String] the prompt to send
      # @param context [String] data to summarize (used for cache hash, prepended to prompt)
      # @param model [String] model to use (default: claude-sonnet-4-6)
      # @return [String, nil] the LLM response text, or nil on failure
      def summarize(prompt, context: nil, model: DEFAULT_MODEL)
        return nil unless available?

        full_prompt = context ? "#{context}\n\n#{prompt}" : prompt
        digest = Digest::SHA256.hexdigest(full_prompt)[0..15]
        cache_key = "#{CACHE_PREFIX}/#{digest}"

        Rails.cache.fetch(cache_key, expires_in: CACHE_EXPIRES_IN) do
          call_api(full_prompt, model: model)
        end
      rescue => e
        Rails.logger.error "LlmService error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        nil
      end

      private

      def api_key
        ENV['ANTHROPIC_API_KEY']
      end

      def call_api(prompt, model:)
        uri = URI(CLAUDE_API_URL)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 15
        http.read_timeout = 60

        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = 'application/json'
        request['x-api-key'] = api_key
        request['anthropic-version'] = '2023-06-01'
        request.body = JSON.generate({
          model: model,
          max_tokens: 1024,
          messages: [{ role: 'user', content: prompt }]
        })

        response = http.request(request)

        unless response.code == '200'
          Rails.logger.error "LlmService API error: #{response.code} - #{response.body.to_s[0..300]}"
          return nil
        end

        parsed = JSON.parse(response.body)
        text_block = parsed.dig('content')&.find { |c| c['type'] == 'text' }
        text_block&.dig('text')
      end
    end
  end
end
