defmodule MishkaCms.PluginEventsTest do
  @moduledoc """
  Every plugin the installed extensions ship is heard. Its application starts it; if it listens on an
  event `PluginHook` fires — `<app>:<resource>:after_<action>` — that event names an action that
  exists, or is the resource's `after_save`, which any of its create and update actions fires; and if
  that action has a master twin, some plugin hears the twin as well.

  Each failure is silent. A plugin no application starts never registers, and a plugin on a name
  nothing fires registers and never runs. Both sides are read off the loaded code — each module of an
  application that can declare a plugin, each resource that carries `PluginHook` — so a plugin, an
  action or an extension added later is checked without being listed here.

  It lives in the host because only here is every extension loaded at once. No extension's
  `test/support` is compiled here either, so every plugin the scan finds is one an extension ships:
  none of them is a test probe that listens on one action on purpose.
  """
  use ExUnit.Case, async: true

  alias MishkaBlog.Notifiers.{PostMasterPublished, PostPublished}
  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  defp modules do
    for {app, _description, _version} <- Application.loaded_applications(),
        :mishka_installer in Application.spec(app, :applications),
        module <- Application.spec(app, :modules),
        Code.ensure_loaded?(module),
        do: {app, module}
  end

  defp plugin?(module) do
    behaviours =
      module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    MishkaInstaller.Event.Hook in behaviours
  end

  # What an application starts is its `plugins/0`. An application without one starts no plugin.
  defp started_plugins(app) do
    with {application, _args} <- Application.spec(app, :mod),
         true <- Code.ensure_loaded?(application),
         true <- function_exported?(application, :plugins, 0) do
      application.plugins()
    else
      _ -> []
    end
  end

  defp fired_events(modules) do
    for {_app, resource} <- modules,
        Ash.Resource.Info.resource?(resource),
        PluginHook in Ash.Resource.Info.notifiers(resource),
        %{type: type, name: name} <- Ash.Resource.Info.actions(resource),
        type in [:create, :update, :destroy],
        event <- events(resource, type, name),
        into: MapSet.new(),
        do: event
  end

  # An action's own event, and its resource's `after_save` for a create or an update.
  defp events(resource, type, name) when type in [:create, :update],
    do: [PluginHook.event_name(resource, name), PluginHook.save_event_name(resource)]

  defp events(resource, _destroy, name), do: [PluginHook.event_name(resource, name)]

  # Whether `event` was meant for `PluginHook`: its app segment is one `PluginHook` fires for, or its
  # `<resource>:after_<action>` is one `PluginHook` fires under some app — so a plugin that spelled
  # the app wrong (`mishka_blog:blog_post:after_publish`) is caught too. An event of any other shape
  # (`settings:register`, `runtime:compile:after_page`) is announced by hand.
  defp hook_shaped?(event, fired) do
    case String.split(event, ":") do
      [app, resource, "after_" <> _ = action] ->
        Enum.any?(fired, fn fired_event ->
          [fired_app, fired_resource, fired_action] = String.split(fired_event, ":")
          fired_app == app or {fired_resource, fired_action} == {resource, action}
        end)

      _ ->
        false
    end
  end

  defp twin(event) do
    [app, resource, "after_" <> action] = String.split(event, ":")

    case action do
      "master_" <> tenant_action -> "#{app}:#{resource}:after_#{tenant_action}"
      tenant_action -> "#{app}:#{resource}:after_master_#{tenant_action}"
    end
  end

  setup_all do
    modules = modules()
    fired = fired_events(modules)

    plugins =
      for {app, module} <- modules,
          plugin?(module),
          do: %{app: app, module: module, event: module.config(:__event__)}

    %{
      fired: fired,
      plugins: plugins,
      listeners: Enum.filter(plugins, &hook_shaped?(&1.event, fired))
    }
  end

  test "the scan sees the post-published notifiers", %{listeners: listeners} do
    for module <- [PostPublished, PostMasterPublished] do
      assert %{app: :mishka_blog, module: module, event: module.config(:__event__)} in listeners
    end
  end

  test "every plugin is started by its application", %{plugins: plugins} do
    unstarted =
      for %{app: app, module: module} <- plugins,
          module not in started_plugins(app),
          do: {app, module}

    assert unstarted == [],
           "these plugins are not in their application's plugins/0, so none of them ever " <>
             "registers: #{inspect(unstarted)}"
  end

  test "every plugin on a PluginHook event names an action that fires it", ctx do
    unfired =
      for %{module: module, event: event} <- ctx.listeners,
          event not in ctx.fired,
          do: {module, event}

    assert unfired == [],
           "these plugins listen on an event no resource action fires: #{inspect(unfired)}"
  end

  test "every plugin on an action with a master twin hears the twin too", ctx do
    heard = MapSet.new(ctx.listeners, & &1.event)

    deaf =
      for %{module: module, event: event} <- ctx.listeners,
          twin(event) in ctx.fired,
          twin(event) not in heard,
          do: {module, twin(event)}

    assert deaf == [], "no plugin hears the master (or tenant) twin of: #{inspect(deaf)}"
  end
end
