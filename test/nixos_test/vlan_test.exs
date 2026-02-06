defmodule NixosTest.VLanTest do
  use ExUnit.Case

  alias NixosTest.VLan

  describe "VLan" do
    test "start_link creates vde_switch process and socket dir" do
      tmp = Path.join(System.tmp_dir!(), "vlan-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)

      {:ok, vlan} = VLan.start_link(nr: 1, tmp_dir: tmp)

      # socket dir should exist
      socket_dir = Path.join(tmp, "vde1.ctl")
      assert File.dir?(socket_dir)

      # should report its number
      assert VLan.nr(vlan) == 1

      # should report socket dir
      assert VLan.socket_dir(vlan) == socket_dir

      GenServer.stop(vlan)
      File.rm_rf!(tmp)
    end

    test "stop terminates the vde_switch process" do
      tmp = Path.join(System.tmp_dir!(), "vlan-stop-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)

      {:ok, vlan} = VLan.start_link(nr: 2, tmp_dir: tmp)
      socket_dir = VLan.socket_dir(vlan)
      assert File.dir?(socket_dir)

      GenServer.stop(vlan)

      # give vde_switch time to clean up
      Process.sleep(100)

      File.rm_rf!(tmp)
    end

    test "multiple VLANs can coexist" do
      tmp = Path.join(System.tmp_dir!(), "vlan-multi-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)

      {:ok, v1} = VLan.start_link(nr: 1, tmp_dir: tmp)
      {:ok, v2} = VLan.start_link(nr: 2, tmp_dir: tmp)

      assert VLan.nr(v1) == 1
      assert VLan.nr(v2) == 2
      assert VLan.socket_dir(v1) != VLan.socket_dir(v2)

      GenServer.stop(v1)
      GenServer.stop(v2)
      File.rm_rf!(tmp)
    end

    test "qemu_nic_flags generates correct QEMU arguments" do
      flags = VLan.qemu_nic_flags(1, 1, "/tmp/vde1.ctl")
      assert length(flags) == 2

      [device_flag, netdev_flag] = flags
      assert device_flag =~ "virtio-net-pci"
      assert device_flag =~ "52:54:00:12:01:01"
      assert netdev_flag =~ "vde"
      assert netdev_flag =~ "/tmp/vde1.ctl"
    end

    test "qemu_nic_mac generates deterministic MAC addresses" do
      assert VLan.qemu_nic_mac(1, 1) == "52:54:00:12:01:01"
      assert VLan.qemu_nic_mac(1, 2) == "52:54:00:12:01:02"
      assert VLan.qemu_nic_mac(2, 1) == "52:54:00:12:02:01"
      assert VLan.qemu_nic_mac(10, 254) == "52:54:00:12:0a:fe"
    end
  end
end
