# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Cms.State do
  @moduledoc """
  Prints one record as plain text: its attributes and the records it belongs to.

  An agent reads the state this way before it acts, and a person reads it to see what the database
  holds, without a screenshot. It proves what the data is; it does not prove a page shows it.

  ## Usage

      mix cms.state site <id>
      mix cms.state page <id> --site <site_id>
      mix cms.state MishkaBlog.Post <id> --site <site_id>

  The resource is a module name or its last part in snake case, among the resources of the domains
  in `config :mishka_cms, :ash_domains`. A record of a site's own needs `--site`. Reads run as the
  system (`authorize?: false`). A sensitive attribute prints as `[sensitive]`.
  """

  use Mix.Task

  @shortdoc "Prints one record and the records it belongs to, as plain text"
  @requirements ["app.start"]
  @label_fields [:name, :title, :path, :email, :host]

  @impl Mix.Task
  def run(args) do
    {opts, rest, _invalid} = OptionParser.parse(args, strict: [site: :string])

    with [name, id] <- rest,
         {:ok, resource} <- resource(name),
         {:ok, record} <- read(resource, id, opts[:site]) do
      Mix.shell().info(describe(resource, record, opts[:site]))
    else
      args when is_list(args) ->
        Mix.raise("Usage: mix cms.state <resource> <id> [--site <site_id>]")

      {:error, message} when is_binary(message) ->
        Mix.raise(message)

      {:error, error} ->
        Mix.raise("Could not read the record: " <> Exception.message(error))
    end
  end

  defp resource(name) do
    case Enum.filter(resources(), &(inspect(&1) == name or short_name(&1) == name)) do
      [resource] ->
        {:ok, resource}

      [] ->
        {:error, "No resource is named #{name}."}

      many ->
        {:error, "#{name} names more than one resource: #{Enum.map_join(many, ", ", &inspect/1)}"}
    end
  end

  defp resources do
    :mishka_cms
    |> Application.fetch_env!(:ash_domains)
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
  end

  defp short_name(resource), do: resource |> Module.split() |> List.last() |> Macro.underscore()

  defp read(resource, id, site), do: Ash.get(resource, id, tenant: site, authorize?: false)

  defp describe(resource, record, site) do
    belongs_to = Enum.filter(Ash.Resource.Info.relationships(resource), &(&1.type == :belongs_to))
    loaded = Ash.load!(record, Enum.map(belongs_to, & &1.name), tenant: site, authorize?: false)

    [
      inspect(resource),
      Enum.map(Ash.Resource.Info.attributes(resource), &attribute_line(&1, record)),
      Enum.map(belongs_to, &relationship_line(&1, loaded))
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp attribute_line(%{sensitive?: true, name: name}, _record), do: "  #{name}: [sensitive]"

  defp attribute_line(%{name: name}, record),
    do: "  #{name}: #{inspect(Map.get(record, name), limit: 20, printable_limit: 120)}"

  defp relationship_line(%{name: name}, record) do
    case Map.get(record, name) do
      nil ->
        "  #{name} → none"

      related ->
        "  #{name} → #{inspect(related.__struct__)} #{Map.get(related, :id)}#{label(related)}"
    end
  end

  defp label(related) do
    case Enum.find_value(@label_fields, &Map.get(related, &1)) do
      nil -> ""
      value -> " (#{value})"
    end
  end
end
