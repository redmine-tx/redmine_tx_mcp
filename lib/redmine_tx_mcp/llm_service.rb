# frozen_string_literal: true

require 'net/http'
require 'json'
require 'digest'

module RedmineTxMcp
  class LlmService
    CLAUDE_API_URL = 'https://api.anthropic.com/v1/messages'
    CACHE_PREFIX = 'llm_service'
    CACHE_EXPIRES_IN = 1.day

    class << self
      # Check if the LLM service is available (API key or endpoint configured)
      def available?
        settings = plugin_settings
        provider = settings['llm_provider'] || 'anthropic'

        if provider == 'openai'
          settings['openai_endpoint_url'].present?
        else
          (settings['claude_api_key'].presence || ENV['ANTHROPIC_API_KEY']).present?
        end
      end

      # Single-shot summarization — no tool use, no conversation history.
      # Results are cached by content hash: same input → cached response, no API call.
      #
      # @param prompt [String] the prompt to send
      # @return [String, nil] the LLM response text, or nil on failure
      def summarize(prompt, context: nil)
        return nil unless available?

        full_prompt = context ? "#{context}\n\n#{prompt}" : prompt
        settings = plugin_settings
        provider = settings['llm_provider'] || 'anthropic'
        model = if provider == 'openai'
                  settings['openai_model'].presence || 'default'
                else
                  settings['claude_model'].presence || 'claude-sonnet-4-6'
                end
        digest = Digest::SHA256.hexdigest("#{provider}:#{model}:#{full_prompt}")[0..15]
        cache_key = "#{CACHE_PREFIX}/#{digest}"

        Rails.cache.fetch(cache_key, expires_in: CACHE_EXPIRES_IN, skip_nil: true) do
          result = call_llm(full_prompt, summarize: true)
          result.present? ? result : nil
        end
      rescue => e
        Rails.logger.error "LlmService error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        nil
      end

      private

      def plugin_settings
        Setting.plugin_redmine_tx_mcp || {}
      rescue
        {}
      end

      def call_llm(prompt, summarize: false)
        settings = plugin_settings
        provider = settings['llm_provider'] || 'anthropic'

        if provider == 'openai'
          call_openai(prompt, settings, summarize: summarize)
        else
          call_anthropic(prompt, settings)
        end
      end

      def call_anthropic(prompt, settings)
        api_key = settings['claude_api_key'].presence || ENV['ANTHROPIC_API_KEY']
        model = settings['claude_model'].presence || 'claude-sonnet-4-6'

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

      def call_openai(prompt, settings, summarize: false)
        endpoint_url = settings['openai_endpoint_url']
        api_key = settings['openai_api_key'].presence
        model = settings['openai_model'].presence || 'default'

        # Use OpenaiAdapter for format conversion
        # Thinking models (e.g. Qwen) consume tokens with reasoning before producing
        # the actual answer — need much higher max_tokens for local models.
        anthropic_request = {
          model: model,
          max_tokens: summarize ? 16384 : 4096,
          messages: [{ role: 'user', content: prompt }]
        }

        response = RedmineTxMcp::OpenaiAdapter.call(
          anthropic_request,
          api_key: api_key,
          endpoint_url: endpoint_url
        )

        text_block = response.dig('content')&.find { |c| c['type'] == 'text' }
        text_block&.dig('text')
      rescue => e
        Rails.logger.error "LlmService OpenAI error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        nil
      end
    end
  end
end
