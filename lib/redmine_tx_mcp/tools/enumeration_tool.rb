module RedmineTxMcp
  module Tools
    class EnumerationTool < BaseTool
      class << self
        def available_tools
          [
            {
              name: "enum_statuses",
              description: "List all issue statuses. Each status has a stage (workflow phase) and is_paused flag from the advanced status plugin. Use this to find valid status_id values before creating or updating issues.",
              inputSchema: {
                type: "object",
                properties: {}
              }
            },
            {
              name: "enum_trackers",
              description: "List all issue trackers (issue types). Use this to find valid tracker_id values. tracker_id is required when creating issues.",
              inputSchema: {
                type: "object",
                properties: {}
              }
            },
            {
              name: "enum_priorities",
              description: "List all issue priorities. Use this to find valid priority_id values.",
              inputSchema: {
                type: "object",
                properties: {}
              }
            },
            {
              name: "enum_categories",
              description: "List issue categories for a specific project. Use this to find valid category_id values.",
              inputSchema: {
                type: "object",
                properties: {
                  project_id: { type: "integer", description: "Project ID" }
                },
                required: ["project_id"]
              }
            },
            {
              name: "enum_roles",
              description: "List all roles. Use this to find valid role_ids when adding project members.",
              inputSchema: {
                type: "object",
                properties: {}
              }
            },
            {
              name: "enum_custom_fields",
              description: "List custom fields available for a given entity type. Returns field ID, name, type, possible values, and whether it is required. Use this to discover valid custom field IDs before reading or setting custom field values on issues, projects, users, or versions.",
              inputSchema: {
                type: "object",
                properties: {
                  type: { type: "string", description: "Entity type", enum: ["issue", "project", "user", "version"] },
                  project_id: { type: "integer", description: "Project ID (only for issue type - filters to custom fields enabled in this project)" },
                  tracker_id: { type: "integer", description: "Tracker ID (only for issue type - filters to custom fields enabled for this tracker)" }
                },
                required: ["type"]
              }
            }
          ]
        end

        def call_tool(tool_name, arguments)
          case tool_name
          when "enum_statuses"
            list_statuses
          when "enum_trackers"
            list_trackers
          when "enum_priorities"
            list_priorities
          when "enum_categories"
            list_categories(arguments)
          when "enum_roles"
            list_roles
          when "enum_custom_fields"
            list_custom_fields(arguments)
          else
            { error: "Unknown tool: #{tool_name}" }
          end
        rescue => e
          handle_error(e)
        end

        private

        def list_statuses
          statuses = IssueStatus.sorted.map do |status|
            result = {
              id: status.id,
              name: status.name,
              is_closed: status.is_closed?
            }
            if status.respond_to?(:stage)
              result[:stage] = status.stage
              result[:stage_name] = status.respond_to?(:stage_name) ? status.stage_name : nil
              result[:is_paused] = status.respond_to?(:is_paused?) ? status.is_paused? : nil
            end
            result
          end
          { statuses: statuses }
        end

        def list_trackers
          trackers = Tracker.sorted.map do |tracker|
            result = {
              id: tracker.id,
              name: tracker.name
            }
            if tracker.respond_to?(:is_in_roadmap)
              result[:is_in_roadmap] = tracker.is_in_roadmap
            end
            if tracker.respond_to?(:is_sidejob)
              result[:is_sidejob] = tracker.is_sidejob
              result[:is_bug] = tracker.is_bug
              result[:is_patchnote] = tracker.is_patchnote
              result[:is_exception] = tracker.is_exception
            end
            result
          end
          { trackers: trackers }
        end

        def list_priorities
          priorities = IssuePriority.active.map do |priority|
            {
              id: priority.id,
              name: priority.name,
              is_default: priority.is_default?,
              position: priority.position
            }
          end
          { priorities: priorities }
        end

        def list_categories(args)
          project = Project.visible.find(args['project_id'])
          categories = project.issue_categories.map do |category|
            {
              id: category.id,
              name: category.name,
              assigned_to: category.assigned_to ? {
                id: category.assigned_to.id,
                name: category.assigned_to.name
              } : nil
            }
          end
          { categories: categories }
        rescue ActiveRecord::RecordNotFound
          { error: "Project not found" }
        end

        def list_roles
          roles = Role.givable.sorted.map do |role|
            {
              id: role.id,
              name: role.name,
              assignable: role.assignable?,
              builtin: role.builtin
            }
          end
          { roles: roles }
        end

        def list_custom_fields(args)
          cf_class = case args['type']
                     when 'issue'   then IssueCustomField
                     when 'project' then ProjectCustomField
                     when 'user'    then UserCustomField
                     when 'version' then VersionCustomField
                     else
                       return { error: "Unknown type: #{args['type']}. Supported: issue, project, user, version" }
                     end

          scope = cf_class.sorted

          if args['type'] == 'issue'
            if args['tracker_id']
              tracker = Tracker.find_by(id: args['tracker_id'])
              scope = scope.where(id: tracker.custom_field_ids) if tracker
            end
            if args['project_id']
              project = Project.find_by(id: args['project_id'])
              if project
                project_cf_ids = project.issue_custom_field_ids
                global_cf_ids = cf_class.where(is_for_all: true).pluck(:id)
                scope = scope.where(id: (project_cf_ids + global_cf_ids).uniq)
              end
            end
          end

          fields = scope.map do |cf|
            result = {
              id: cf.id,
              name: cf.name,
              field_format: cf.field_format,
              is_required: cf.is_required?,
              is_filter: cf.is_filter?,
              searchable: cf.searchable?,
              multiple: cf.multiple?,
              default_value: cf.default_value.presence,
              description: cf.description.presence
            }
            if cf.possible_values.present?
              result[:possible_values] = cf.possible_values
            end
            if cf.field_format == 'list' || cf.field_format == 'enumeration'
              result[:possible_values] = cf.possible_values
            end
            result
          end

          { custom_fields: fields }
        end
      end
    end
  end
end
