require 'csv'
require 'date'
require 'rexml/document'
require 'set'
require 'zip'

module RedmineTxMcp
  class SpreadsheetDocument
    BUILTIN_DATE_NUMFMTS = [14, 15, 16, 17, 18, 19, 20, 21, 22, 45, 46, 47].freeze
    MAX_PREVIEW_ROWS = 50
    MAX_PREVIEW_COLUMNS = 20
    MAX_EXTRACT_ROWS = 300

    def initialize(path)
      @path = path
      @extension = File.extname(path).downcase
      raise ArgumentError, "Unsupported spreadsheet format: #{@extension}" unless supported?
    end

    def list_sheets
      sheets.map.with_index(1) do |sheet, index|
        {
          index: index,
          name: sheet[:name],
          row_count: sheet[:rows].length,
          column_count: max_column_count(sheet[:rows]),
          dimension: build_dimension(sheet[:rows])
        }
      end
    end

    def preview_sheet(sheet_name: nil, sheet_index: nil, start_row: 1, max_rows: 20, max_columns: 12)
      sheet = find_sheet(sheet_name: sheet_name, sheet_index: sheet_index)
      start_row = [start_row.to_i, 1].max
      max_rows = [[max_rows.to_i, 1].max, MAX_PREVIEW_ROWS].min
      max_columns = [[max_columns.to_i, 1].max, MAX_PREVIEW_COLUMNS].min

      selected_rows = sheet[:rows].drop(start_row - 1).first(max_rows)
      preview_rows = selected_rows.each_with_index.map do |row, offset|
        build_preview_row(start_row + offset, row, max_columns)
      end

      {
        file_name: File.basename(@path),
        sheet_name: sheet[:name],
        start_row: start_row,
        returned_rows: preview_rows.length,
        total_rows: sheet[:rows].length,
        has_more: sheet[:rows].length > (start_row - 1 + preview_rows.length),
        rows: preview_rows
      }
    end

    def extract_rows(sheet_name: nil, sheet_index: nil, header_row: 1, row_offset: 0, row_limit: 100, columns: nil)
      sheet = find_sheet(sheet_name: sheet_name, sheet_index: sheet_index)
      header_row = [header_row.to_i, 1].max
      row_offset = [row_offset.to_i, 0].max
      row_limit = [[row_limit.to_i, 1].max, MAX_EXTRACT_ROWS].min

      header_values = sheet[:rows][header_row - 1] || []
      normalized_headers = normalize_headers(header_values)
      requested_columns = normalize_requested_columns(columns, normalized_headers)
      rows = sheet[:rows].drop(header_row + row_offset).first(row_limit)
      structured_rows = rows.map.with_index do |row, offset|
        build_structured_row(header_row + row_offset + offset + 1, requested_columns, normalized_headers, row)
      end

      {
        file_name: File.basename(@path),
        sheet_name: sheet[:name],
        header_row: header_row,
        row_offset: row_offset,
        returned_rows: structured_rows.length,
        total_data_rows: [sheet[:rows].length - header_row, 0].max,
        has_more: [sheet[:rows].length - header_row - row_offset - structured_rows.length, 0].max.positive?,
        columns: requested_columns,
        rows: structured_rows
      }
    end

    def self.build_xlsx(sheet_name:, columns:, rows:, summary_lines: [])
      sheets = []
      used_sheet_names = Set.new
      if summary_lines.present?
        summary_rows = summary_lines.map { |line| [line.to_s] }
        sheets << {
          name: normalize_sheet_name('Summary', used_sheet_names),
          columns: ['Summary'],
          rows: summary_rows
        }
      end

      normalized_columns = Array(columns).map(&:to_s)
      data_rows = Array(rows).map do |row|
        normalized_columns.map { |column| row[column] || row[column.to_sym] }
      end
      sheets << {
        name: normalize_sheet_name(sheet_name.to_s.presence || 'Report', used_sheet_names),
        columns: normalized_columns,
        rows: data_rows
      }

      build_workbook_archive(sheets)
    end

    private

    def supported?
      %w[.xlsx .csv .tsv].include?(@extension)
    end

    def sheets
      @sheets ||= @extension == '.xlsx' ? load_xlsx_sheets : [load_delimited_sheet]
    end

    def load_delimited_sheet
      separator = @extension == '.tsv' ? "\t" : ','
      rows = CSV.read(@path, col_sep: separator, encoding: 'bom|utf-8').map { |row| normalize_row(row) }
      {
        name: File.basename(@path),
        rows: rows
      }
    rescue CSV::MalformedCSVError => e
      raise ArgumentError, "Failed to read spreadsheet: #{e.message}"
    end

    def load_xlsx_sheets
      with_zip do |zip|
        workbook_doc = xml_doc(zip.read('xl/workbook.xml'))
        relationships = load_relationships(zip)
        shared_strings = load_shared_strings(zip)
        date_styles = load_date_styles(zip)

        xpath(workbook_doc, "//*[local-name()='sheet']").map do |sheet_element|
          name = sheet_element.attributes['name']
          rel_id = relation_id(sheet_element)
          target = relationships[rel_id]
          next unless target

          worksheet_xml = zip.read(target)
          {
            name: name,
            rows: parse_worksheet(worksheet_xml, shared_strings, date_styles)
          }
        end.compact
      end
    end

    def load_relationships(zip)
      rels_doc = xml_doc(zip.read('xl/_rels/workbook.xml.rels'))
      xpath(rels_doc, "//*[local-name()='Relationship']").each_with_object({}) do |element, memo|
        target = element.attributes['Target'].to_s
        next if target.blank?

        memo[element.attributes['Id']] = target.start_with?('xl/') ? target : File.join('xl', target)
      end
    end

    def load_shared_strings(zip)
      return [] unless zip.find_entry('xl/sharedStrings.xml')

      doc = xml_doc(zip.read('xl/sharedStrings.xml'))
      xpath(doc, "//*[local-name()='si']").map do |element|
        collect_text(element)
      end
    end

    def load_date_styles(zip)
      return Set.new unless zip.find_entry('xl/styles.xml')

      doc = xml_doc(zip.read('xl/styles.xml'))
      custom_formats = {}
      xpath(doc, "//*[local-name()='numFmt']").each do |element|
        custom_formats[element.attributes['numFmtId'].to_i] = element.attributes['formatCode'].to_s
      end

      date_style_indexes = Set.new
      xpath(doc, "//*[local-name()='cellXfs']/*[local-name()='xf']").each_with_index do |element, index|
        num_fmt_id = element.attributes['numFmtId'].to_i
        format_code = custom_formats[num_fmt_id]
        if BUILTIN_DATE_NUMFMTS.include?(num_fmt_id) || date_format_code?(format_code)
          date_style_indexes << index
        end
      end
      date_style_indexes
    end

    def parse_worksheet(xml, shared_strings, date_styles)
      doc = xml_doc(xml)
      rows = []
      xpath(doc, "//*[local-name()='sheetData']/*[local-name()='row']").each do |row_element|
        row_values = []
        xpath(row_element, "./*[local-name()='c']").each do |cell_element|
          index = cell_index(cell_element.attributes['r'].to_s)
          row_values[index] = parse_cell_value(cell_element, shared_strings, date_styles)
        end
        rows << normalize_row(row_values)
      end
      rows
    end

    def parse_cell_value(cell_element, shared_strings, date_styles)
      type = cell_element.attributes['t'].to_s
      style_index = cell_element.attributes['s'].to_i
      value_element = xpath(cell_element, "./*[local-name()='v']").first
      value = value_element&.text.to_s

      case type
      when 's'
        shared_strings[value.to_i]
      when 'inlineStr'
        inline = xpath(cell_element, "./*[local-name()='is']").first
        collect_text(inline)
      when 'b'
        value == '1'
      when 'str'
        value
      else
        parse_numeric_or_string(value, date_styles.include?(style_index))
      end
    end

    def parse_numeric_or_string(value, date_style)
      return nil if value.blank?

      if date_style
        excel_serial_to_iso(value.to_f)
      elsif value.match?(/\A-?\d+\z/)
        value.to_i
      elsif value.match?(/\A-?\d+\.\d+\z/)
        value.to_f
      else
        value
      end
    end

    def excel_serial_to_iso(serial)
      date_time = Time.utc(1899, 12, 30) + (serial * 86_400)
      if serial.to_i == serial
        date_time.strftime('%Y-%m-%d')
      else
        date_time.strftime('%Y-%m-%d %H:%M:%S')
      end
    end

    def normalize_row(row)
      Array(row).map { |value| normalize_value(value) }.tap do |values|
        values.pop while values.last.nil?
      end
    end

    def normalize_value(value)
      case value
      when nil
        nil
      when String
        stripped = value.strip
        stripped.presence
      else
        value
      end
    end

    def build_preview_row(row_number, row, max_columns)
      values = Array(row).first(max_columns)
      preview = { row_number: row_number }
      values.each_with_index do |value, index|
        preview[:"col_#{index + 1}"] = value
      end
      preview
    end

    def normalize_headers(header_values)
      seen = Hash.new(0)
      Array(header_values).map.with_index do |value, index|
        base = value.to_s.strip
        base = "column_#{index + 1}" if base.blank?
        key = base.gsub(/\s+/, '_').gsub(/[^A-Za-z0-9_가-힣]/, '_').gsub(/_+/, '_').gsub(/\A_+|_+\z/, '')
        key = "column_#{index + 1}" if key.blank?
        seen[key] += 1
        seen[key] == 1 ? key : "#{key}_#{seen[key]}"
      end
    end

    def normalize_requested_columns(columns, normalized_headers)
      requested = Array(columns).map(&:to_s).reject(&:blank?)
      requested.present? ? requested : normalized_headers
    end

    def build_structured_row(row_number, requested_columns, normalized_headers, row)
      structured = { row_number: row_number }
      requested_columns.each do |column_name|
        index = normalized_headers.index(column_name)
        structured[column_name] = index ? row[index] : nil
      end
      structured
    end

    def find_sheet(sheet_name: nil, sheet_index: nil)
      if sheet_name.present?
        sheet = sheets.find { |candidate| candidate[:name].casecmp(sheet_name.to_s).zero? }
        raise ArgumentError, "Sheet not found: #{sheet_name}" unless sheet

        return sheet
      end

      if sheet_index.present?
        index = sheet_index.to_i
        raise ArgumentError, "Invalid sheet index: #{sheet_index}" unless index.positive?

        sheet = sheets[index - 1]
        raise ArgumentError, "Sheet not found at index #{index}" unless sheet

        return sheet
      end

      sheets.first || raise(ArgumentError, 'Spreadsheet does not contain any sheets')
    end

    def max_column_count(rows)
      rows.map(&:length).max || 0
    end

    def build_dimension(rows)
      row_count = rows.length
      column_count = max_column_count(rows)
      return nil if row_count.zero? || column_count.zero?

      "A1:#{column_letters(column_count)}#{row_count}"
    end

    def cell_index(reference)
      letters = reference.to_s[/[A-Z]+/i].to_s.upcase
      return 0 if letters.blank?

      letters.chars.reduce(0) { |sum, char| (sum * 26) + char.ord - 64 } - 1
    end

    def column_letters(index)
      value = index.to_i
      letters = +''
      while value.positive?
        value -= 1
        letters.prepend((65 + (value % 26)).chr)
        value /= 26
      end
      letters
    end

    def collect_text(node)
      return '' unless node

      texts = []
      xpath(node, ".//*[local-name()='t']").each { |text_node| texts << text_node.text.to_s }
      texts.presence&.join || node.text.to_s
    end

    def xml_doc(xml)
      REXML::Document.new(xml)
    end

    def xpath(node, expression)
      REXML::XPath.match(node, expression)
    end

    def relation_id(element)
      element.attributes['r:id'] || element.attributes["{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"]
    end

    def with_zip
      Zip::File.open(@path) do |zip|
        yield zip
      end
    rescue Zip::Error => e
      raise ArgumentError, "Failed to read xlsx file: #{e.message}"
    end

    def date_format_code?(format_code)
      return false if format_code.blank?

      lowered = format_code.downcase.gsub(/"[^"]*"/, '')
      lowered.match?(/[ymdhis]/)
    end

    def self.build_workbook_archive(sheets)
      buffer = Zip::OutputStream.write_buffer do |zip|
        zip.put_next_entry('[Content_Types].xml')
        zip.write(content_types_xml(sheets.length))

        zip.put_next_entry('_rels/.rels')
        zip.write(root_relationships_xml)

        zip.put_next_entry('xl/workbook.xml')
        zip.write(workbook_xml(sheets))

        zip.put_next_entry('xl/_rels/workbook.xml.rels')
        zip.write(workbook_relationships_xml(sheets.length))

        zip.put_next_entry('xl/styles.xml')
        zip.write(styles_xml)

        sheets.each_with_index do |sheet, index|
          zip.put_next_entry("xl/worksheets/sheet#{index + 1}.xml")
          zip.write(sheet_xml(sheet[:columns], sheet[:rows]))
        end
      end
      buffer.string
    end

    def self.content_types_xml(sheet_count)
      worksheet_overrides = (1..sheet_count).map do |index|
        %(<Override PartName="/xl/worksheets/sheet#{index}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>)
      end.join

      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
          #{worksheet_overrides}
        </Types>
      XML
    end

    def self.root_relationships_xml
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
      XML
    end

    def self.workbook_xml(sheets)
      sheet_nodes = sheets.each_with_index.map do |sheet, index|
        %(<sheet name="#{xml_escape(sheet[:name].to_s[0, 31])}" sheetId="#{index + 1}" r:id="rId#{index + 1}"/>)
      end.join

      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>#{sheet_nodes}</sheets>
        </workbook>
      XML
    end

    def self.workbook_relationships_xml(sheet_count)
      sheet_relationships = (1..sheet_count).map do |index|
        %(<Relationship Id="rId#{index}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet#{index}.xml"/>)
      end.join

      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          #{sheet_relationships}
        </Relationships>
      XML
    end

    def self.styles_xml
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>
          <fills count="1"><fill><patternFill patternType="none"/></fill></fills>
          <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
          <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
          <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>
        </styleSheet>
      XML
    end

    def self.sheet_xml(columns, rows)
      data_rows = [Array(columns)] + Array(rows)
      row_nodes = data_rows.each_with_index.map do |row, row_index|
        cells = Array(row).each_with_index.map do |value, column_index|
          reference = "#{column_letters_static(column_index + 1)}#{row_index + 1}"
          cell_xml(reference, value)
        end.join
        %(<row r="#{row_index + 1}">#{cells}</row>)
      end.join

      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>#{row_nodes}</sheetData>
        </worksheet>
      XML
    end

    def self.cell_xml(reference, value)
      if value.nil?
        %(<c r="#{reference}"/>)
      elsif value.is_a?(Numeric)
        %(<c r="#{reference}"><v>#{value}</v></c>)
      elsif value == true || value == false
        %(<c r="#{reference}" t="b"><v>#{value ? 1 : 0}</v></c>)
      else
        escaped = xml_escape(value.to_s)
        %(<c r="#{reference}" t="inlineStr"><is><t>#{escaped}</t></is></c>)
      end
    end

    def self.column_letters_static(index)
      value = index.to_i
      letters = +''
      while value.positive?
        value -= 1
        letters.prepend((65 + (value % 26)).chr)
        value /= 26
      end
      letters
    end

    def self.xml_escape(value)
      value.to_s
        .gsub('&', '&amp;')
        .gsub('<', '&lt;')
        .gsub('>', '&gt;')
        .gsub('"', '&quot;')
        .gsub("'", '&apos;')
    end

    def self.normalize_sheet_name(name, used_names)
      base = name.to_s.gsub(/[\\\/\?\*\[\]:]/, '_').strip
      base = base.gsub(/\A'+|'+\z/, '')
      base = 'Sheet' if base.blank?

      candidate = base[0, 31]
      suffix = 2
      while used_names.include?(candidate.downcase)
        suffix_label = "_#{suffix}"
        candidate = "#{base[0, 31 - suffix_label.length]}#{suffix_label}"
        suffix += 1
      end

      used_names << candidate.downcase
      candidate
    end
  end
end
