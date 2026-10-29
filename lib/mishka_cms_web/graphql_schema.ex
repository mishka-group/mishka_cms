# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.GraphqlSchema do
  @moduledoc """
  What `/gql` and the `/ws/gql` socket (`MishkaCmsWeb.GraphqlSocket`) answer. AshGraphql draws no
  domain into it yet (`domains: []`), so it carries only the sample `say_hello` query.
  """
  use Absinthe.Schema

  use AshGraphql,
    domains: []

  import_types Absinthe.Plug.Types

  query do
    # Custom Absinthe queries can be placed here
    @desc """
    Hello! This is a sample query to verify that AshGraphql has been set up correctly.
    Remove me once you have a query of your own!
    """
    field :say_hello, :string do
      resolve fn _, _, _ ->
        {:ok, "Hello from AshGraphql!"}
      end
    end
  end

  mutation do
    # Custom Absinthe mutations can be placed here
  end

  subscription do
    # Custom Absinthe subscriptions can be placed here
  end
end
