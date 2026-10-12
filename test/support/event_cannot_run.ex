defmodule MishkaCms.Test.EventCannotRun do
  @moduledoc """
  Makes mishka_installer events answer as events whose plugins are not all loaded — `Hook.call/3`
  runs none of them and answers its `cannot_run:` option, or the state it is given — for one test,
  and puts each back as it was when the test exits: rebuilt from its stored plugins, or not compiled
  at all when it was not, so `Hook.call/3` hands the state straight back again.

  The compiled event is global, so a test using this is `async: false`.

      setup do: MishkaCms.Test.EventCannotRun.stub!("web:request:site_unavailable")
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias MishkaInstaller.Event.{EventHandler, ModuleStateCompiler}

  @not_loaded MishkaCms.Test.EventCannotRun.NotLoadedPlugin

  @spec stub!(String.t() | [String.t()]) :: :ok
  def stub!(events) do
    for event <- List.wrap(events) do
      compiled? = function_exported?(ModuleStateCompiler.module_event_name(event), :call, 2)
      :ok = ModuleStateCompiler.purge_create([], event, [@not_loaded])
      on_exit(fn -> restore(event, compiled?) end)
    end

    :ok
  end

  defp restore(event, true), do: EventHandler.do_compile(event, :start, false)
  defp restore(event, false), do: ModuleStateCompiler.purge(event)
end
