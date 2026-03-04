module RedmineTxMcp
  module Tools
    class ProjectTool < BaseTool
      class << self
        def available_tools
          [
            {
              name: "project_list",
              description: "List projects with filtering and pagination",
              inputSchema: {
                type: "object",
                properties: {
                  name: { type: "string", description: "Filter by project name" },
                  identifier: { type: "string", description: "Filter by project identifier" },
                  status: { type: "integer", description: "Filter by status (1=active, 2=closed, 9=archived)" },
                  is_public: { type: "boolean", description: "Filter by public/private status" },
                  parent_id: { type: "integer", description: "Filter by parent project ID" },
                  page: { type: "integer", description: "Page number", default: 1 },
                  per_page: { type: "integer", description: "Items per page (max 100)", default: 25 }
                }
              }
            },
            {
              name: "project_get",
              description: "Get detailed information about a specific project",
              inputSchema: {
                type: "object",
                properties: {
                  id: { type: "integer", description: "Project ID", required: true }
                },
                required: ["id"]
              }
            },
            {
              name: "project_create",
              description: "Create a new project",
              inputSchema: {
                type: "object",
                properties: {
                  name: { type: "string", description: "Project name", required: true },
                  identifier: { type: "string", description: "Project identifier", required: true },
                  description: { type: "string", description: "Project description" },
                  homepage: { type: "string", description: "Project homepage URL" },
                  is_public: { type: "boolean", description: "Is project public", default: false },
                  parent_id: { type: "integer", description: "Parent project ID" },
                  inherit_members: { type: "boolean", description: "Inherit members from parent", default: false },
                  tracker_ids: { type: "array", items: { type: "integer" }, description: "Tracker IDs to enable" },
                  enabled_module_names: { type: "array", items: { type: "string" }, description: "Module names to enable" }
                },
                required: ["name", "identifier"]
              }
            },
            {
              name: "project_update",
              description: "Update an existing project",
              inputSchema: {
                type: "object",
                properties: {
                  id: { type: "integer", description: "Project ID", required: true },
                  name: { type: "string", description: "Project name" },
                  identifier: { type: "string", description: "Project identifier" },
                  description: { type: "string", description: "Project description" },
                  homepage: { type: "string", description: "Project homepage URL" },
                  is_public: { type: "boolean", description: "Is project public" },
                  parent_id: { type: "integer", description: "Parent project ID" },
                  inherit_members: { type: "boolean", description: "Inherit members from parent" },
                  status: { type: "integer", description: "Project status (1=active, 2=closed, 9=archived)" },
                  tracker_ids: { type: "array", items: { type: "integer" }, description: "Tracker IDs to enable" },
                  enabled_module_names: { type: "array", items: { type: "string" }, description: "Module names to enable" }
                },
                required: ["id"]
              }
            },
            {
              name: "project_delete",
              description: "Delete a project",
              inputSchema: {
                type: "object",
                properties: {
                  id: { type: "integer", description: "Project ID", required: true }
                },
                required: ["id"]
              }
            },
            {
              name: "project_members",
              description: "Get project members",
              inputSchema: {
                type: "object",
                properties: {
                  project_id: { type: "integer", description: "Project ID", required: true },
                  page: { type: "integer", description: "Page number", default: 1 },
                  per_page: { type: "integer", description: "Items per page (max 100)", default: 25 }
                },
                required: ["project_id"]
              }
            },
            {
              name: "project_add_member",
              description: "Add a member to a project",
              inputSchema: {
                type: "object",
                properties: {
                  project_id: { type: "integer", description: "Project ID", required: true },
                  user_id: { type: "integer", description: "User ID", required: true },
                  role_ids: { type: "array", items: { type: "integer" }, description: "Role IDs", required: true }
                },
                required: ["project_id", "user_id", "role_ids"]
              }
            },
            {
              name: "project_remove_member",
              description: "Remove a member from a project",
              inputSchema: {
                type: "object",
                properties: {
                  project_id: { type: "integer", description: "Project ID", required: true },
                  user_id: { type: "integer", description: "User ID", required: true }
                },
                required: ["project_id", "user_id"]
              }
            }
          ]
        end

        def call_tool(tool_name, arguments)
          case tool_name
          when "project_list"
            list_projects(arguments)
          when "project_get"
            get_project(arguments)
          when "project_create"
            create_project(arguments)
          when "project_update"
            update_project(arguments)
          when "project_delete"
            delete_project(arguments)
          when "project_members"
            get_project_members(arguments)
          when "project_add_member"
            add_project_member(arguments)
          when "project_remove_member"
            remove_project_member(arguments)
          else
            { error: "Unknown tool: #{tool_name}" }
          end
        rescue => e
          handle_error(e)
        end

        private

        def list_projects(args)
          scope = Project.visible

          # Apply filters
          if args['name']
            scope = scope.where("LOWER(name) LIKE ?", "%#{args['name'].downcase}%")
          end
          if args['identifier']
            scope = scope.where("LOWER(identifier) LIKE ?", "%#{args['identifier'].downcase}%")
          end
          scope = scope.where(status: args['status']) if args['status']
          scope = scope.where(is_public: args['is_public']) unless args['is_public'].nil?
          scope = scope.where(parent_id: args['parent_id']) if args['parent_id']

          scope = scope.includes(:parent)
          scope = scope.order(:name)

          paginate_results(scope, page: args['page'], per_page: args['per_page'])
        end

        def get_project(args)
          project = Project.visible.find(args['id'])
          format_project_details(project)
        rescue ActiveRecord::RecordNotFound
          { error: "Project not found" }
        end

        def create_project(args)
          project = Project.new
          project.name = args['name']
          project.identifier = args['identifier']
          project.description = args['description'] if args['description']
          project.homepage = args['homepage'] if args['homepage']
          project.is_public = args['is_public'] unless args['is_public'].nil?
          project.parent_id = args['parent_id'] if args['parent_id']
          project.inherit_members = args['inherit_members'] unless args['inherit_members'].nil?

          if args['tracker_ids']
            project.tracker_ids = args['tracker_ids']
          end

          if args['enabled_module_names']
            project.enabled_module_names = args['enabled_module_names']
          end

          if project.save
            format_project_details(project)
          else
            { error: "Failed to create project", validation_errors: project.errors.full_messages }
          end
        end

        def update_project(args)
          project = Project.visible.find(args['id'])

          project.name = args['name'] if args['name']
          project.identifier = args['identifier'] if args['identifier']
          project.description = args['description'] if args['description']
          project.homepage = args['homepage'] if args['homepage']
          project.is_public = args['is_public'] unless args['is_public'].nil?
          project.parent_id = args['parent_id'] if args['parent_id']
          project.inherit_members = args['inherit_members'] unless args['inherit_members'].nil?
          project.status = args['status'] if args['status']

          if args['tracker_ids']
            project.tracker_ids = args['tracker_ids']
          end

          if args['enabled_module_names']
            project.enabled_module_names = args['enabled_module_names']
          end

          if project.save
            format_project_details(project)
          else
            { error: "Failed to update project", validation_errors: project.errors.full_messages }
          end
        rescue ActiveRecord::RecordNotFound
          { error: "Project not found" }
        end

        def delete_project(args)
          project = Project.visible.find(args['id'])

          if project.destroy
            { success: true, message: "Project deleted successfully" }
          else
            { error: "Failed to delete project", validation_errors: project.errors.full_messages }
          end
        rescue ActiveRecord::RecordNotFound
          { error: "Project not found" }
        end

        def get_project_members(args)
          project = Project.visible.find(args['project_id'])
          scope = project.members.includes(:principal, :roles)

          paginate_results(scope, page: args['page'], per_page: args['per_page'])
        rescue ActiveRecord::RecordNotFound
          { error: "Project not found" }
        end

        def add_project_member(args)
          project = Project.visible.find(args['project_id'])
          user = User.find(args['user_id'])

          member = Member.new
          member.project = project
          member.principal = user
          member.role_ids = args['role_ids']

          if member.save
            format_response(member)
          else
            { error: "Failed to add member", validation_errors: member.errors.full_messages }
          end
        rescue ActiveRecord::RecordNotFound => e
          { error: "Resource not found: #{e.message}" }
        end

        def remove_project_member(args)
          project = Project.visible.find(args['project_id'])
          member = project.members.joins(:principal).where(principals: { id: args['user_id'] }).first

          if member&.destroy
            { success: true, message: "Member removed successfully" }
          else
            { error: "Member not found or failed to remove" }
          end
        rescue ActiveRecord::RecordNotFound
          { error: "Project not found" }
        end

        def format_project_details(project)
          {
            id: project.id,
            name: project.name,
            identifier: project.identifier,
            description: project.description,
            homepage: project.homepage,
            is_public: project.is_public,
            status: project.status,
            parent: project.parent ? {
              id: project.parent.id,
              name: project.parent.name,
              identifier: project.parent.identifier
            } : nil,
            inherit_members: project.inherit_members,
            created_on: project.created_on&.iso8601,
            updated_on: project.updated_on&.iso8601,
            trackers: project.trackers.map { |t| { id: t.id, name: t.name } },
            enabled_modules: project.enabled_modules.map(&:name),
            members_count: project.members.count,
            issues_count: project.issues.count
          }
        end
      end
    end
  end
end