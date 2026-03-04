module RedmineTxMcp
  module Tools
    class UserTool < BaseTool
      class << self
        def available_tools
          [
            {
              name: "user_list",
              description: "List users with filtering and pagination",
              inputSchema: {
                type: "object",
                properties: {
                  name: { type: "string", description: "Filter by name (firstname or lastname)" },
                  login: { type: "string", description: "Filter by login" },
                  mail: { type: "string", description: "Filter by email" },
                  status: { type: "integer", description: "Filter by status (1=active, 2=registered, 3=locked)" },
                  group_id: { type: "integer", description: "Filter by group membership" },
                  page: { type: "integer", description: "Page number", default: 1 },
                  per_page: { type: "integer", description: "Items per page (max 100)", default: 25 }
                }
              }
            },
            {
              name: "user_get",
              description: "Get detailed information about a specific user",
              inputSchema: {
                type: "object",
                properties: {
                  id: { type: "integer", description: "User ID", required: true }
                },
                required: ["id"]
              }
            },
            {
              name: "user_create",
              description: "Create a new user",
              inputSchema: {
                type: "object",
                properties: {
                  login: { type: "string", description: "User login", required: true },
                  firstname: { type: "string", description: "First name", required: true },
                  lastname: { type: "string", description: "Last name", required: true },
                  mail: { type: "string", description: "Email address", required: true },
                  password: { type: "string", description: "Password" },
                  language: { type: "string", description: "Language code (e.g., 'en', 'ja')" },
                  admin: { type: "boolean", description: "Is administrator", default: false },
                  status: { type: "integer", description: "User status (1=active, 2=registered, 3=locked)", default: 1 },
                  auth_source_id: { type: "integer", description: "Authentication source ID" },
                  must_change_passwd: { type: "boolean", description: "Must change password on next login", default: false }
                },
                required: ["login", "firstname", "lastname", "mail"]
              }
            },
            {
              name: "user_update",
              description: "Update an existing user",
              inputSchema: {
                type: "object",
                properties: {
                  id: { type: "integer", description: "User ID", required: true },
                  login: { type: "string", description: "User login" },
                  firstname: { type: "string", description: "First name" },
                  lastname: { type: "string", description: "Last name" },
                  mail: { type: "string", description: "Email address" },
                  password: { type: "string", description: "Password" },
                  language: { type: "string", description: "Language code" },
                  admin: { type: "boolean", description: "Is administrator" },
                  status: { type: "integer", description: "User status (1=active, 2=registered, 3=locked)" },
                  auth_source_id: { type: "integer", description: "Authentication source ID" },
                  must_change_passwd: { type: "boolean", description: "Must change password on next login" }
                },
                required: ["id"]
              }
            },
            {
              name: "user_delete",
              description: "Delete a user",
              inputSchema: {
                type: "object",
                properties: {
                  id: { type: "integer", description: "User ID", required: true }
                },
                required: ["id"]
              }
            },
            {
              name: "user_projects",
              description: "Get projects where user is a member",
              inputSchema: {
                type: "object",
                properties: {
                  user_id: { type: "integer", description: "User ID", required: true },
                  page: { type: "integer", description: "Page number", default: 1 },
                  per_page: { type: "integer", description: "Items per page (max 100)", default: 25 }
                },
                required: ["user_id"]
              }
            },
            {
              name: "user_groups",
              description: "Get groups where user is a member",
              inputSchema: {
                type: "object",
                properties: {
                  user_id: { type: "integer", description: "User ID", required: true }
                },
                required: ["user_id"]
              }
            },
            {
              name: "user_roles",
              description: "Get user's roles across all projects",
              inputSchema: {
                type: "object",
                properties: {
                  user_id: { type: "integer", description: "User ID", required: true }
                },
                required: ["user_id"]
              }
            }
          ]
        end

        def call_tool(tool_name, arguments)
          case tool_name
          when "user_list"
            list_users(arguments)
          when "user_get"
            get_user(arguments)
          when "user_create"
            create_user(arguments)
          when "user_update"
            update_user(arguments)
          when "user_delete"
            delete_user(arguments)
          when "user_projects"
            get_user_projects(arguments)
          when "user_groups"
            get_user_groups(arguments)
          when "user_roles"
            get_user_roles(arguments)
          else
            { error: "Unknown tool: #{tool_name}" }
          end
        rescue => e
          handle_error(e)
        end

        private

        def list_users(args)
          scope = User.visible

          # Apply filters
          if args['name']
            scope = scope.where(
              "LOWER(firstname) LIKE ? OR LOWER(lastname) LIKE ?",
              "%#{args['name'].downcase}%",
              "%#{args['name'].downcase}%"
            )
          end
          if args['login']
            scope = scope.where("LOWER(login) LIKE ?", "%#{args['login'].downcase}%")
          end
          if args['mail']
            scope = scope.where("LOWER(mail) LIKE ?", "%#{args['mail'].downcase}%")
          end
          scope = scope.where(status: args['status']) if args['status']

          if args['group_id']
            scope = scope.joins(:groups).where(groups: { id: args['group_id'] })
          end

          scope = scope.order(:lastname, :firstname)

          paginate_results(scope, page: args['page'], per_page: args['per_page'])
        end

        def get_user(args)
          user = User.visible.find(args['id'])
          format_user_details(user)
        rescue ActiveRecord::RecordNotFound
          { error: "User not found" }
        end

        def create_user(args)
          user = User.new
          user.login = args['login']
          user.firstname = args['firstname']
          user.lastname = args['lastname']
          user.mail = args['mail']
          user.password = args['password'] if args['password']
          user.language = args['language'] || 'en'
          user.admin = args['admin'] || false
          user.status = args['status'] || User::STATUS_ACTIVE
          user.auth_source_id = args['auth_source_id'] if args['auth_source_id']
          user.must_change_passwd = args['must_change_passwd'] || false

          if user.save
            format_user_details(user)
          else
            { error: "Failed to create user", validation_errors: user.errors.full_messages }
          end
        end

        def update_user(args)
          user = User.visible.find(args['id'])

          user.login = args['login'] if args['login']
          user.firstname = args['firstname'] if args['firstname']
          user.lastname = args['lastname'] if args['lastname']
          user.mail = args['mail'] if args['mail']
          user.password = args['password'] if args['password']
          user.language = args['language'] if args['language']
          user.admin = args['admin'] unless args['admin'].nil?
          user.status = args['status'] if args['status']
          user.auth_source_id = args['auth_source_id'] if args['auth_source_id']
          user.must_change_passwd = args['must_change_passwd'] unless args['must_change_passwd'].nil?

          if user.save
            format_user_details(user)
          else
            { error: "Failed to update user", validation_errors: user.errors.full_messages }
          end
        rescue ActiveRecord::RecordNotFound
          { error: "User not found" }
        end

        def delete_user(args)
          user = User.visible.find(args['id'])

          if user.destroy
            { success: true, message: "User deleted successfully" }
          else
            { error: "Failed to delete user", validation_errors: user.errors.full_messages }
          end
        rescue ActiveRecord::RecordNotFound
          { error: "User not found" }
        end

        def get_user_projects(args)
          user = User.visible.find(args['user_id'])
          scope = user.projects.visible

          paginate_results(scope, page: args['page'], per_page: args['per_page'])
        rescue ActiveRecord::RecordNotFound
          { error: "User not found" }
        end

        def get_user_groups(args)
          user = User.visible.find(args['user_id'])
          groups = user.groups.map do |group|
            {
              id: group.id,
              name: group.name,
              builtin: group.builtin,
              created_on: group.created_on&.iso8601,
              updated_on: group.updated_on&.iso8601
            }
          end
          { groups: groups }
        rescue ActiveRecord::RecordNotFound
          { error: "User not found" }
        end

        def get_user_roles(args)
          user = User.visible.find(args['user_id'])
          roles = user.roles_for_projects(Project.visible).group_by(&:project).map do |project, project_roles|
            {
              project: {
                id: project.id,
                name: project.name,
                identifier: project.identifier
              },
              roles: project_roles.map do |role|
                {
                  id: role.id,
                  name: role.name,
                  builtin: role.builtin,
                  assignable: role.assignable,
                  permissions: role.permissions
                }
              end
            }
          end
          { project_roles: roles }
        rescue ActiveRecord::RecordNotFound
          { error: "User not found" }
        end

        def format_user_details(user)
          {
            id: user.id,
            login: user.login,
            firstname: user.firstname,
            lastname: user.lastname,
            mail: user.mail,
            admin: user.admin?,
            status: user.status,
            status_name: user.status_name,
            language: user.language,
            created_on: user.created_on&.iso8601,
            updated_on: user.updated_on&.iso8601,
            last_login_on: user.last_login_on&.iso8601,
            passwd_changed_on: user.passwd_changed_on&.iso8601,
            must_change_passwd: user.must_change_passwd?,
            auth_source: user.auth_source ? {
              id: user.auth_source.id,
              name: user.auth_source.name,
              type: user.auth_source.type
            } : nil,
            groups: user.groups.map { |g| { id: g.id, name: g.name } },
            custom_fields: user.custom_field_values.map do |cfv|
              {
                id: cfv.custom_field.id,
                name: cfv.custom_field.name,
                value: cfv.value
              }
            end
          }
        end
      end
    end
  end
end