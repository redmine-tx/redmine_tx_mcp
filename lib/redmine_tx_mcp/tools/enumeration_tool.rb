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
      end
    end
  end
end
