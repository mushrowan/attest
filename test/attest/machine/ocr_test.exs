defmodule Attest.Machine.OCRTest do
  use ExUnit.Case, async: true

  alias Attest.Machine.OCR

  # tiny 4x4 white PPM image (valid format for tesseract)
  @test_ppm "P6\n4 4\n255\n" <> :binary.copy(<<255, 255, 255>>, 16)

  setup do
    dir = Path.join(System.tmp_dir!(), "ocr-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "run_tesseract/1" do
    @tag :ocr
    test "returns {:ok, text} on success", %{dir: dir} do
      img = Path.join(dir, "test.ppm")
      File.write!(img, @test_ppm)

      assert {:ok, text} = OCR.run_tesseract(img)
      assert is_binary(text)
    end

    test "returns {:error, :not_found} when tesseract missing" do
      assert {:error, :not_found} =
               OCR.run_tesseract("/nonexistent.ppm", tesseract: "nonexistent-bin-xxx")
    end
  end

  describe "preprocess/2" do
    @tag :ocr
    test "creates a preprocessed image file", %{dir: dir} do
      img = Path.join(dir, "test.ppm")
      File.write!(img, @test_ppm)

      assert {:ok, out_path} = OCR.preprocess(img, negate: false)
      assert File.exists?(out_path)
      assert String.contains?(out_path, "positive")
    end

    @tag :ocr
    test "negate creates a negated variant", %{dir: dir} do
      img = Path.join(dir, "test.ppm")
      File.write!(img, @test_ppm)

      assert {:ok, out_path} = OCR.preprocess(img, negate: true)
      assert File.exists?(out_path)
      assert String.contains?(out_path, "negative")
    end

    test "returns {:error, :not_found} when magick missing", %{dir: dir} do
      img = Path.join(dir, "test.ppm")
      File.write!(img, @test_ppm)

      assert {:error, :not_found} = OCR.preprocess(img, magick: "nonexistent-bin-xxx")
    end
  end

  describe "perform_ocr/1" do
    @tag :ocr
    test "runs OCR on a screenshot and returns text", %{dir: dir} do
      img = Path.join(dir, "screenshot.ppm")
      File.write!(img, @test_ppm)

      assert {:ok, text} = OCR.perform_ocr(img)
      assert is_binary(text)
    end
  end

  describe "perform_ocr_variants/1" do
    @tag :ocr
    test "returns a list of text variants", %{dir: dir} do
      img = Path.join(dir, "screenshot.ppm")
      File.write!(img, @test_ppm)

      assert {:ok, variants} = OCR.perform_ocr_variants(img)
      assert is_list(variants)
      assert length(variants) == 3
      assert Enum.all?(variants, &is_binary/1)
    end
  end
end
