# Tesseract language data

`flutter_tesseract_ocr` loads the trained data files listed in
`assets/tessdata_config.json` from this folder.

`eng.traineddata` (from
[`tessdata_fast`](https://github.com/tesseract-ocr/tessdata_fast)) is bundled
so the title OCR works out of the box. To swap in the more accurate (larger)
standard model, replace it with the file from
[`tessdata`](https://github.com/tesseract-ocr/tessdata) and keep the same name.
