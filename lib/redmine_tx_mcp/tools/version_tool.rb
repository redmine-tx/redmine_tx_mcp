module RedmineTxMcp
  module Tools
    class VersionTool < BaseTool
      class << self
        def available_tools
          [
            {
              name: "version_list",
              description: "List versions (milestones) for a project. Versions represent release milestones that issues can be assigned to via fixed_version_id.",
              inputSchema: {
                type: "object",
                properties: {
                  project_id: { type: "integer", description: "Project ID (required)" },
                  name: { type: "string", description: "Filter by name (partial match, e.g. '0318' finds 'Sprint 0318')" },
                  status: { type: "string", description: "Filter by status", enum: ["open", "locked", "closed"] },
                  sharing: { type: "string", description: "Filter by sharing scope", enum: ["none", "descendants", "hierarchy", "tree", "system"] },
                  include_subprojects: { type: "boolean", description: "Include versions from subprojects", default: false },
                  page: { type: "integer", description: "Page number", default: 1 },
                  per_page: { type: "integer", description: "Items per page (max 100)", default: 25 }
                },
                required: ["project_id"]
              }
            },
            {
              name: "version_get",
              description: "Get detailed information about a specific version including progress statistics",
              inputSchema: {
                type: "object",
                properties: {
                  id: { type: "integer", description: "Version ID" }
                },
                required: ["id"]
              }
            },
            {
              name: "version_create",
              description: "Create a new version (milestone) for a project",
              inputSchema: {
                type: "object",
                properties: {
                  project_id: { type: "integer", description: "Project ID" },
                  name: { type: "string", description: "Version name" },
                  description: { type: "string", description: "Version description" },
                  status: { type: "string", description: "Version status", enum: ["open", "locked", "closed"], default: "open" },
                  sharing: { type: "string", description: "Sharing scope", enum: ["none", "descendants", "hierarchy", "tree", "system"], default: "none" },
                  due_date: { type: "string", description: "Due date (YYYY-MM-DD)" },
                  wiki_page_title: { type: "string", description: "Associated wiki page title" }
                },
                required: ["project_id", "name"]
              }
            },
            {
              name: "version_update",
              description: "Update an existing version",
              inputSchema: {
                type: "object",
                properties: {
                  id: { type: "integer", description: "Version ID" },
                  name: { type: "string", description: "Version name" },
                  description: { type: "string", description: "Version description" },
                  status: { type: "string", description: "Version status", enum: ["open", "locked", "closed"] },
                  sharing: { type: "string", description: "Sharing scope", enum: ["none", "descendants", "hierarchy", "tree", "system"] },
                  due_date: { type: "string", description: "Due date (YYYY-MM-DD)" },
                  wiki_page_title: { type: "string", description: "Associated wiki page title" }
                },
                required: ["id"]
              }
            },
            {
              name: "version_delete",
              description: "Delete a version. Fails if version has associated issues.",
              inputSchema: {
                type: "object",
                properties: {
                  id: { type: "integer", description: "Version ID" }
                },
                required: ["id"]
              }
            },
            {
              name: "version_statistics",
              description: "Get statistics for a version: issue counts by status/tracker, hours, and completion percentage",
              inputSchema: {
                type: "object",
                properties: {
                  id: { type: "integer", description: "Version ID" }
                },
                required: ["id"]
              }
            }
          ]
        end

        def call_tool(tool_name, arguments)
          case tool_name
          when "version_list"
            list_versions(arguments)
          when "version_get"
            get_version(arguments)
          when "version_create"
            create_version(arguments)
          when "version_update"
            update_version(arguments)
          when "version_delete"
            delete_version(arguments)
          when "version_statistics"
            get_version_statistics(arguments)
          else
            { error: "Unknown tool: #{tool_name}" }
          end
        rescue => e
          handle_error(e)
        end

        private

        def list_versions(args)
          project = Project.visible.find(args['project_id'])

          versions = project.versions.visible
          versions = versions.where(status: args['status']) if args['status']
          versions = versions.where(sharing: args['sharing']) if args['sharing']
          versions = versions.where("#{Version.table_name}.name LIKE ?", "%#{args['name']}%") if args['name'].present?

          if args['include_subprojects']
            subproject_ids = project.descendants.active.pluck(:id)
            versions = Version.visible.where(project_id: [project.id] + subproject_ids)
            versions = versions.where(status: args['status']) if args['status']
            versions = versions.where(sharing: args['sharing']) if args['sharing']
            versions = versions.where("#{Version.table_name}.name LIKE ?", "%#{args['name']}%") if args['name'].present?
          end

          page = [args['page'].to_i, 1].max
          per_page = [[args['per_page'].to_i, 1].max, 100].min
          total = versions.count
          offset = (page - 1) * per_page
          items = versions.order(effective_date: :desc, name: :asc).offset(offset).limit(per_page).to_a

          {
            items: items.map { |v| format_version(v) },
            pagination: {
              page: page,
              per_page: per_page,
              total_count: total,
              total_pages: (total.to_f / per_page).ceil
            }
          }
        rescue ActiveRecord::RecordNotFound
          { error: "Project not found" }
        end

        def get_version(args)
          version = Version.find(args['id'])
          format_version(version, detailed: true)
        rescue ActiveRecord::RecordNotFound
          { error: "Version not found" }
        end

        def create_version(args)
          project = Project.visible.find(args['project_id'])

          version = project.versions.build
          version.name = args['name']
          version.description = args['description'] if args['description']
          version.status = args['status'] || 'open'
          version.sharing = args['sharing'] || 'none'
          version.effective_date = args['due_date'] if args['due_date']
          version.wiki_page_title = args['wiki_page_title'] if args['wiki_page_title']

          if version.save
            format_version(version)
          else
            { error: "Failed to create version", validation_errors: version.errors.full_messages }
          end
        rescue ActiveRecord::RecordNotFound
          { error: "Project not found" }
        end

        def update_version(args)
          version = Version.find(args['id'])

          version.name = args['name'] if args['name']
          version.description = args['description'] if args.key?('description')
          version.status = args['status'] if args['status']
          version.sharing = args['sharing'] if args['sharing']
          version.effective_date = args['due_date'] if args.key?('due_date')
          version.wiki_page_title = args['wiki_page_title'] if args.key?('wiki_page_title')

          if version.save
            format_version(version)
          else
            { error: "Failed to update version", validation_errors: version.errors.full_messages }
          end
        rescue ActiveRecord::RecordNotFound
          { error: "Version not found" }
        end

        def delete_version(args)
          version = Version.find(args['id'])

          if version.deletable?
            version.destroy
            { success: true, message: "Version deleted successfully" }
          else
            { error: "Version cannot be deleted (has associated issues)" }
          end
        rescue ActiveRecord::RecordNotFound
          { error: "Version not found" }
        end

        def get_version_statistics(args)
          version = Version.find(args['id'])
          issues = version.fixed_issues.visible

          {
            version: format_version(version),
            statistics: {
              total_issues: issues.count,
              open_issues: issues.open.count,
              closed_issues: issues.where(status_id: IssueStatus.where(is_closed: true).pluck(:id)).count,
              estimated_hours: issues.sum(:estimated_hours) || 0,
              spent_hours: issues.joins(:time_entries).sum(:hours) || 0,
              done_ratio: version.completed_percent,
              issues_by_status: IssueStatus.all.map { |status|
                count = issues.where(status_id: status.id).count
                { id: status.id, name: status.name, count: count } if count > 0
              }.compact,
              issues_by_tracker: Tracker.all.map { |tracker|
                count = issues.where(tracker_id: tracker.id).count
                { id: tracker.id, name: tracker.name, count: count } if count > 0
              }.compact
            }
          }
        rescue ActiveRecord::RecordNotFound
          { error: "Version not found" }
        end

        def format_version(version, detailed: false)
          result = {
            id: version.id,
            name: version.name,
            project: {
              id: version.project_id,
              name: version.project.name,
              identifier: version.project.identifier
            },
            description: version.description,
            status: version.status,
            sharing: version.sharing,
            due_date: version.effective_date&.iso8601,
            created_on: version.created_on&.iso8601,
            updated_on: version.updated_on&.iso8601,
            wiki_page_title: version.wiki_page_title
          }

          if detailed
            result[:completed_percent] = version.completed_percent
            result[:behind_schedule] = version.behind_schedule?
            result[:overdue] = version.overdue?
            result[:closed_issues_count] = version.closed_issues_count
            result[:open_issues_count] = version.open_issues_count
            result[:estimated_hours] = version.estimated_hours
            result[:spent_hours] = version.spent_hours
          end

          result
        end
      end
    end
  end
end
