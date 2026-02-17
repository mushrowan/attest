defmodule Attest.Application do
  @moduledoc """
  OTP Application for Attest.

  Starts the supervision tree for managing test infrastructure.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # registry for machine processes
      {Registry, keys: :unique, name: Attest.MachineRegistry},
      # dynamic supervisor for machines
      {DynamicSupervisor, name: Attest.MachineSupervisor, strategy: :one_for_one},
      # dynamic supervisor for vlans
      {DynamicSupervisor, name: Attest.VLanSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: Attest.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
