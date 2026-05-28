import 'package:fabscan/src/vision/ocr_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OcrService.parseHocr', () {
    test('joins words and averages word confidences', () {
      const hocr = '''
<div class='ocr_page'><span class='ocr_line'>
  <span class='ocrx_word' id='word_1_1' title='bbox 1 2 3 4; x_wconf 96'>Command</span>
  <span class='ocrx_word' id='word_1_2' title='bbox 5 6 7 8; x_wconf 90'>and</span>
  <span class='ocrx_word' id='word_1_3' title='bbox 9 1 2 3; x_wconf 84'>Conquer</span>
</span></div>''';
      final r = OcrService.parseHocr(hocr);
      expect(r.text, 'Command and Conquer');
      expect(r.confidence, closeTo(90, 0.01)); // (96+90+84)/3
    });

    test('unescapes HTML entities in word text', () {
      const hocr =
          "<span class='ocrx_word' title='bbox 0 0 1 1; x_wconf 88'>Rhinar&#39;s</span>";
      final r = OcrService.parseHocr(hocr);
      expect(r.text, "Rhinar's");
      expect(r.confidence, 88);
    });

    test('punctuation-only words do not drag down the mean', () {
      const hocr = '''
<span class='ocrx_word' title='x_wconf 95'>Snatch</span>
<span class='ocrx_word' title='x_wconf 3'>,</span>''';
      final r = OcrService.parseHocr(hocr);
      expect(r.text, 'Snatch ,');
      expect(r.confidence, 95); // the lone comma is excluded from the mean
    });

    test('empty / wordless hOCR yields empty text and zero confidence', () {
      final r = OcrService.parseHocr('<div class="ocr_page"></div>');
      expect(r.text, '');
      expect(r.confidence, 0);
    });
  });
}
