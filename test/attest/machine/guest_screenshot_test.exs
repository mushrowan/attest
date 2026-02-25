defmodule Attest.Machine.GuestScreenshotTest do
  use ExUnit.Case

  alias Attest.Machine.GuestScreenshot

  describe "build_capture_command/1" do
    test "uses fbgrab for virtual console" do
      cmd = GuestScreenshot.build_capture_command(:fbgrab)
      assert cmd =~ "fbgrab"
      assert cmd =~ ".png"
    end

    test "uses import for X11" do
      cmd = GuestScreenshot.build_capture_command(:x11)
      assert cmd =~ "import"
      assert cmd =~ "DISPLAY"
    end

    test "uses xdg-screensaver fallback for wayland" do
      cmd = GuestScreenshot.build_capture_command(:grim)
      assert cmd =~ "grim"
    end
  end

  describe "parse_transfer_command/1" do
    test "generates base64 encode + cat pipeline for a given path" do
      cmd = GuestScreenshot.transfer_command("/tmp/screen.png")
      assert cmd =~ "base64"
      assert cmd =~ "/tmp/screen.png"
    end
  end
end
