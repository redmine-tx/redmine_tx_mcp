require 'cgi'
require 'fileutils'
require 'time'

module RedmineTxMcp
  class ChatbotWorkspace
    MAX_UPLOAD_BYTES = 10 * 1024 * 1024
    SUPPORTED_EXTENSIONS = %w[.xlsx .csv .tsv].freeze

    def initialize(user_id:, project_id:, session_id:)
      @user_id = Integer(user_id)
      @project_id = Integer(project_id)
      @session_id = sanitize_session_id(session_id)
    end

    attr_reader :user_id, :project_id, :session_id

    def root_path
      @root_path ||= File.join(
        Rails.root,
        'tmp',
        'redmine_tx_mcp',
        'chatbot_workspace',
        "user-#{user_id}",
        "project-#{project_id}",
        "session-#{session_id}"
      )
    end

    def uploads_dir
      File.join(root_path, 'uploads')
    end

    def reports_dir
      File.join(root_path, 'reports')
    end

    def list_uploads
      list_files(uploads_dir)
    end

    def list_reports
      list_files(reports_dir).map do |file|
        file.merge(
          download_path: Rails.application.routes.url_helpers.chatbot_report_download_path(
            project_id: project_id,
            filename: file[:stored_name],
            conversation: session_id
          )
        )
      end
    end

    def save_upload(upload)
      raise ArgumentError, 'Uploaded file is missing' if upload.blank?

      original_name = upload.original_filename.to_s
      ext = File.extname(original_name).downcase
      unless SUPPORTED_EXTENSIONS.include?(ext)
        raise ArgumentError, "Unsupported file type: #{ext.presence || 'unknown'}"
      end

      size = upload_size(upload)
      if size > MAX_UPLOAD_BYTES
        raise ArgumentError, "File is too large (max #{MAX_UPLOAD_BYTES / 1024 / 1024} MB)"
      end

      FileUtils.mkdir_p(uploads_dir)
      stored_name = next_available_name(uploads_dir, original_name)
      target_path = File.join(uploads_dir, stored_name)

      File.open(target_path, 'wb') do |file|
        source = upload.respond_to?(:tempfile) ? upload.tempfile : upload
        source.rewind if source.respond_to?(:rewind)
        IO.copy_stream(source, file)
      end

      file_metadata(target_path)
    end

    def save_report(file_name:, content:)
      FileUtils.mkdir_p(reports_dir)
      normalized_name = normalize_report_name(file_name)
      stored_name = next_available_name(reports_dir, normalized_name)
      target_path = File.join(reports_dir, stored_name)
      File.binwrite(target_path, content)
      file_metadata(target_path).merge(
        download_path: Rails.application.routes.url_helpers.chatbot_report_download_path(
          project_id: project_id,
          filename: stored_name,
          conversation: session_id
        )
      )
    end

    def resolve_upload(name = nil)
      resolve_file(uploads_dir, name)
    end

    def resolve_report(name)
      resolve_file(reports_dir, name)
    end

    def clear!
      FileUtils.rm_rf(root_path)
    end

    def summary
      {
        uploads: list_uploads,
        reports: list_reports
      }
    end

    private

    def sanitize_session_id(value)
      cleaned = value.to_s.gsub(/[^A-Za-z0-9_-]/, '')
      cleaned.present? ? cleaned : 'default'
    end

    def upload_size(upload)
      return upload.size if upload.respond_to?(:size) && upload.size

      source = upload.respond_to?(:tempfile) ? upload.tempfile : upload
      source.respond_to?(:size) ? source.size : 0
    end

    def normalize_report_name(file_name)
      base = sanitize_filename(file_name)
      base = 'chatbot-report.xlsx' if base.blank?
      base = "#{base}.xlsx" unless File.extname(base).casecmp('.xlsx').zero?
      base
    end

    def sanitize_filename(file_name)
      base = File.basename(file_name.to_s.strip)
      return '' if base.blank? || %w[. ..].include?(base)

      stem = File.basename(base, '.*').gsub(/[^A-Za-z0-9._-]+/, '_').gsub(/\A[._]+|[._]+\z/, '')
      ext = File.extname(base).gsub(/[^A-Za-z0-9.]+/, '')
      stem = 'file' if stem.blank?
      "#{stem}#{ext.downcase}"
    end

    def next_available_name(dir, preferred_name)
      safe_name = sanitize_filename(preferred_name)
      stem = File.basename(safe_name, '.*')
      ext = File.extname(safe_name)
      candidate = "#{stem}#{ext}"
      index = 2

      while File.exist?(File.join(dir, candidate))
        candidate = "#{stem}_#{index}#{ext}"
        index += 1
      end

      candidate
    end

    def resolve_file(dir, requested_name)
      candidates = list_files(dir)
      raise ArgumentError, 'No files are available in this session' if candidates.empty?

      return candidates.last.merge(path: File.join(dir, candidates.last[:stored_name])) if requested_name.blank? && candidates.size == 1
      raise ArgumentError, "Multiple files are available: #{candidates.map { |f| f[:stored_name] }.join(', ')}" if requested_name.blank?

      match = match_file(candidates, requested_name.to_s)
      raise ArgumentError, "File not found: #{requested_name}" unless match

      match.merge(path: File.join(dir, match[:stored_name]))
    end

    def match_file(candidates, requested_name)
      normalized = requested_name.strip.downcase
      exact = candidates.find { |file| file[:stored_name].downcase == normalized }
      return exact if exact

      basename = File.basename(normalized)
      candidates.find { |file| file[:stored_name].downcase == basename }
    end

    def list_files(dir)
      return [] unless Dir.exist?(dir)

      Dir.children(dir).sort.map do |name|
        path = File.join(dir, name)
        next unless File.file?(path)

        file_metadata(path)
      end.compact.sort_by { |file| [file[:uploaded_at], file[:stored_name]] }
    end

    def file_metadata(path)
      stat = File.stat(path)
      {
        stored_name: File.basename(path),
        size_bytes: stat.size,
        size_label: human_size(stat.size),
        uploaded_at: stat.mtime.iso8601,
        extension: File.extname(path).downcase
      }
    end

    def human_size(size)
      units = %w[B KB MB GB]
      value = size.to_f
      unit = units.shift
      while value >= 1024 && units.any?
        value /= 1024.0
        unit = units.shift
      end
      value >= 10 || unit == 'B' ? "#{value.round} #{unit}" : "#{value.round(1)} #{unit}"
    end
  end
end
