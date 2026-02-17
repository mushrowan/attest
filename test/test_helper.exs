Application.ensure_all_started(:nixos_test)

# skip :ocr tests when tesseract/imagemagick aren't installed
exclude =
  if System.find_executable("tesseract") == nil do
    [:ocr]
  else
    []
  end

ExUnit.start(exclude: exclude)
