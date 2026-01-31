defmodule NixosTest.Application do
  @moduledoc """
  OTP Application for NixosTest.

  Starts the supervision tree for managing test infrastructure.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # registry for machine processes
      {Registry, keys: :unique, name: NixosTest.MachineRegistry},
      # dynamic supervisor for machines
      {DynamicSupervisor, name: NixosTest.MachineSupervisor, strategy: :one_for_one},
      # dynamic supervisor for vlans
      {DynamicSupervisor, name: NixosTest.VLanSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: NixosTest.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
