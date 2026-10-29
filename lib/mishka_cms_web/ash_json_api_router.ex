# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.AshJsonApiRouter do
  @moduledoc """
  JSON:API for the Runtime, Accounts, Blog and Document domains, which the router forwards
  `/api/json` to. `modify_open_api_spec/3` titles the OpenAPI spec and adds the `X-No-Tenant` header
  to every operation; the router serves that spec itself, behind `:api_docs`.
  """
  @domains [
    MishkaCmsCore.Runtime,
    MishkaCmsCore.Accounts,
    MishkaBlog,
    MishkaDocument
  ]

  # `use AshJsonApi.Router` generates `domains/0` from this list. The host router reads it when it
  # mounts `/api/json/open_api` behind the `:api_docs` permission — the spec names every route,
  # filter and field of every resource, and this router answers under `:api` alone — so the gated
  # spec route and the API it describes cannot drift apart.
  use AshJsonApi.Router,
    domains: @domains,
    open_api: "/open_api",
    modify_open_api: {__MODULE__, :modify_open_api_spec, []}

  def modify_open_api_spec(spec, _, _) do
    version = Application.spec(:mishka_cms, :vsn) |> to_string()

    %{
      spec
      | info: %{
          spec.info
          | title: "MishkaCMS API",
            version: version,
            description: "MishkaCMS API Version #{version}"
        },
        paths: add_tenant_headers_to_paths(spec.paths)
    }
  end

  defp add_tenant_headers_to_paths(paths) do
    tenant_parameters = [
      %OpenApiSpex.Parameter{
        in: :header,
        name: "X-No-Tenant",
        required: false,
        description: "Set to 'true' to disable tenant filtering",
        schema: %OpenApiSpex.Schema{
          type: :string,
          enum: ["true", "false"],
          default: "false"
        }
      }
    ]

    Map.new(paths, fn {path, %OpenApiSpex.PathItem{} = path_item} ->
      updated_item = %{
        path_item
        | get: add_params(path_item.get, tenant_parameters),
          post: add_params(path_item.post, tenant_parameters),
          put: add_params(path_item.put, tenant_parameters),
          patch: add_params(path_item.patch, tenant_parameters),
          delete: add_params(path_item.delete, tenant_parameters)
      }

      {path, updated_item}
    end)
  end

  defp add_params(nil, _), do: nil

  defp add_params(%OpenApiSpex.Operation{} = op, params) do
    %{op | parameters: (op.parameters || []) ++ params}
  end
end
