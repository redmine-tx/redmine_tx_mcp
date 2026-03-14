module RedmineTxMcp
  class LlmFormatEncoder
    TABLE_COLUMN_THRESHOLD = 6

    def self.encode(data)
      new.encode(data)
    end

    def encode(data)
      return "" if data.nil?
      return data.to_s if data.is_a?(String)

      if data.is_a?(Hash)
        # Error response
        if (data.key?(:error) || data.key?("error")) && data.keys.size <= 2
          return (data[:error] || data["error"]).to_s
        end

        # Paginated response: {items: [...], pagination: {...}, ...metadata}
        if paginated_hash?(data)
          return encode_paginated_hash(data)
        end

        encode_hash(data)
      elsif data.is_a?(Array)
        if uniform_hash_array?(data)
          encode_collection(data)
        else
          data.map { |item| encode(item) }.join("\n")
        end
      else
        encode_scalar(data)
      end
    end

    private

    # ─── Paginated response ──────────────────────────────

    def paginated_hash?(data)
      (data.key?(:items) || data.key?("items")) && (data.key?(:pagination) || data.key?("pagination"))
    end

    def encode_paginated_hash(data)
      items = data[:items] || data["items"]
      pagination = data[:pagination] || data["pagination"] || {}
      lines = [encode_paginated(items, pagination)]

      extras = data.each_with_object({}) do |(key, value), memo|
        next if %w[items pagination].include?(key.to_s)
        memo[key] = value
      end
      extras_text = encode_hash(extras)
      lines << "" << extras_text if extras_text.present?

      lines.join("\n")
    end

    def encode_paginated(items, pagination)
      lines = []
      p = pagination
      page = p[:page] || p["page"]
      per_page = p[:per_page] || p["per_page"]
      total_count = p[:total_count] || p["total_count"]
      total_pages = p[:total_pages] || p["total_pages"]
      lines << "page: #{page} | per_page: #{per_page} | total: #{total_count} | pages: #{total_pages}"

      if items.is_a?(Array) && items.any?
        if uniform_hash_array?(items)
          lines << ""
          lines << encode_collection(items)
        else
          items.each do |item|
            lines << ""
            lines << encode(item)
          end
        end
      end

      lines.join("\n")
    end

    # ─── Hash (recursive) ────────────────────────────────

    def encode_hash(hash, depth = 0)
      lines = []

      hash.each do |key, value|
        key_s = key.to_s

        case value
        when Array
          if value.empty?
            # skip empty arrays
          elsif uniform_hash_array?(value)
            lines << "" if lines.any?
            lines << heading(depth + 2, key_s)
            lines << ""
            lines << encode_collection(value)
          else
            rendered = value.map { |v| encode_scalar(v) }.reject(&:empty?)
            lines << "#{key_s}: #{rendered.join(", ")}" if rendered.any?
          end
        when Hash
          if value.empty?
            # skip empty hashes
          elsif compact_hash?(value)
            line = format_compact_hash(key_s, value)
            lines << line if line
          else
            # Complex hash — subsection with heading
            lines << "" if lines.any?
            lines << heading(depth + 2, key_s)
            lines << ""
            lines << encode_hash(value, depth + 1)
          end
        when nil
          # skip nil values
        else
          lines << "#{key_s}: #{encode_scalar(value)}"
        end
      end

      lines.join("\n")
    end

    # ─── Collection: Table or TOON based on column count ─

    def encode_collection(items)
      return "" if items.empty?

      columns, flat_items = flatten_items_for_table(items)
      return "" if columns.empty?

      if columns.size <= TABLE_COLUMN_THRESHOLD
        render_markdown_table(columns, flat_items)
      else
        render_toon(columns, flat_items)
      end
    end

    def render_markdown_table(columns, flat_items)
      header = "| #{columns.map(&:to_s).join(" | ")} |"
      separator = "| #{columns.map { |_| "---" }.join(" | ")} |"

      rows = flat_items.map do |item|
        cells = columns.map { |col| escape_pipe(encode_scalar(item[col])) }
        "| #{cells.join(" | ")} |"
      end

      [header, separator, *rows].join("\n")
    end

    def render_toon(columns, flat_items)
      flat_items.map do |item|
        pairs = columns.filter_map do |col|
          val = item[col]
          next if val.nil? || val == ""
          "#{col}=#{encode_scalar(val)}"
        end
        pairs.join(", ")
      end.join("\n")
    end

    # ─── Flatten nested hashes in array items ────────────

    def flatten_items_for_table(items)
      # Collect all keys preserving first-appearance order
      ordered_keys = []
      items.each do |item|
        item.each_key { |k| ordered_keys << k unless ordered_keys.include?(k) }
      end

      # Determine which keys have simple Hash values (flatten one level)
      hash_keys = {}
      ordered_keys.each do |key|
        sub_keys = nil
        items.each do |item|
          val = item[key]
          next unless val.is_a?(Hash)
          # Only flatten hashes whose values are all scalar
          next unless val.values.none? { |v| v.is_a?(Hash) || v.is_a?(Array) }
          sub_keys ||= []
          val.each_key { |sub| sub_keys << sub unless sub_keys.include?(sub) }
        end
        hash_keys[key] = sub_keys if sub_keys
      end

      # Build ordered column list
      columns = []
      ordered_keys.each do |key|
        if hash_keys.key?(key)
          hash_keys[key].each { |sub| columns << :"#{key}_#{sub}" }
        else
          columns << key
        end
      end

      # Build flattened rows
      flat_items = items.map do |item|
        flat = {}
        ordered_keys.each do |key|
          if hash_keys.key?(key)
            sub_keys = hash_keys[key]
            if item[key].is_a?(Hash)
              sub_keys.each { |sub| flat[:"#{key}_#{sub}"] = item[key][sub] }
            else
              sub_keys.each { |sub| flat[:"#{key}_#{sub}"] = nil }
            end
          else
            flat[key] = item[key]
          end
        end
        flat
      end

      [columns, flat_items]
    end

    # ─── Helpers ─────────────────────────────────────────

    # A hash is "compact" if all values are scalar (no nested Hash/Array)
    def compact_hash?(hash)
      hash.values.none? { |v| v.is_a?(Hash) || v.is_a?(Array) }
    end

    # Returns nil if all non-name values are nil (skip the line)
    def format_compact_hash(key, hash)
      if hash.key?(:name) || hash.key?("name")
        name = hash[:name] || hash["name"]
        others = hash.reject { |k, v| k.to_s == "name" || v.nil? }
        if others.any?
          extras = others.map { |k, v| "#{k}=#{encode_scalar(v)}" }.join(", ")
          "#{key}: #{name} (#{extras})"
        elsif name && name != ""
          "#{key}: #{name}"
        end
      else
        non_nil = hash.reject { |_, v| v.nil? }
        return nil if non_nil.empty?
        extras = non_nil.map { |k, v| "#{k}=#{encode_scalar(v)}" }.join(", ")
        "#{key}: #{extras}"
      end
    end

    def uniform_hash_array?(arr)
      arr.is_a?(Array) && arr.size > 0 && arr.all? { |item| item.is_a?(Hash) }
    end

    def encode_scalar(value)
      case value
      when nil then ""
      when true, false then value.to_s
      when Integer, Float then value.to_s
      when String then value.gsub(/[\r\n]+/, " ")
      when Hash
        non_nil = value.reject { |_, v| v.nil? }
        if non_nil.values.any? { |v| v.is_a?(Hash) || v.is_a?(Array) }
          non_nil.map { |k, v| "#{k}: #{encode_scalar(v)}" }.join("; ")
        else
          non_nil.map { |k, v| "#{k}=#{encode_scalar(v)}" }.join(", ")
        end
      when Array then value.map { |v| encode_scalar(v) }.join(", ")
      else value.to_s
      end
    end

    def escape_pipe(str)
      str.to_s.gsub("|", "\\|")
    end

    def heading(level, text)
      "#{"#" * [level, 6].min} #{text}"
    end
  end
end
