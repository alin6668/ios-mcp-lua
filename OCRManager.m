#import "OCRManager.h"
#import "ScreenManager.h"
#import "MCPLogger.h"
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>

#define OCR_LOG(fmt, ...) [MCPLogger log:@"[OCR] " fmt, ##__VA_ARGS__]

@implementation OCRManager

+ (instancetype)sharedInstance {
    static OCRManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[OCRManager alloc] init];
    });
    return instance;
}

static double OCRNum(NSDictionary *d, NSString *k) {
    id v = d[k];
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0.0;
}

// Downsample a CGImage so its longest edge is at most maxEdge pixels, via CoreGraphics.
// Vision text recognition does not need full-resolution input; shrinking a large iPad
// capture (e.g. 1620x2160) cuts recognition time several fold. Returns NULL if no
// downsample is needed or on failure (caller then keeps the original). Coordinate mapping
// is unaffected: results are mapped back using the logical UIImage.size, not pixel size.
static CGImageRef OCRCreateDownsampled(CGImageRef src, CGFloat maxEdge) CF_RETURNS_RETAINED {
    if (!src) return NULL;
    size_t w = CGImageGetWidth(src);
    size_t h = CGImageGetHeight(src);
    size_t longEdge = MAX(w, h);
    if (longEdge == 0 || longEdge <= (size_t)maxEdge) return NULL;

    double scale = maxEdge / (double)longEdge;
    size_t nw = (size_t)(w * scale);
    size_t nh = (size_t)(h * scale);
    if (nw == 0 || nh == 0) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, nw, nh, 8, 0, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, nw, nh), src);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
}

- (NSDictionary *)recognizeTextWithLanguages:(NSArray<NSString *> *)languages
                               minConfidence:(double)minConfidence
                                      region:(NSDictionary *)region
                                        fast:(BOOL)fast
                                       error:(NSString **)error {
    if (error) *error = nil;

    if (@available(iOS 13.0, *)) {
        UIImage *image = [[ScreenManager sharedInstance] captureScreenImage];
        if (!image || !image.CGImage) {
            if (error) *error = @"Failed to capture screen for OCR";
            return nil;
        }

        // UIImage.size is in points and matches the screen's logical size; OCR results are
        // mapped back to these points so the returned rect/tap are tap_screen-ready.
        CGFloat W = image.size.width;
        CGFloat H = image.size.height;

        __block NSArray<VNRecognizedTextObservation *> *observations = nil;
        __block NSError *visionError = nil;

        VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *req, NSError *err) {
            visionError = err;
            observations = (NSArray<VNRecognizedTextObservation *> *)req.results;
        }];
        request.recognitionLevel = fast ? VNRequestTextRecognitionLevelFast : VNRequestTextRecognitionLevelAccurate;
        request.usesLanguageCorrection = !fast; // fast 模式跳过语言矫正以最大化速度
        if (languages.count > 0) {
            request.recognitionLanguages = languages;
        } else {
            request.recognitionLanguages = @[@"zh-Hans", @"en-US"];
        }

        // Limit OCR to a region of interest if provided (Vision uses normalized, origin bottom-left).
        if ([region isKindOfClass:[NSDictionary class]] && region.count > 0 && W > 0 && H > 0) {
            double rx = OCRNum(region, @"x"), ry = OCRNum(region, @"y");
            double rw = OCRNum(region, @"width"), rh = OCRNum(region, @"height");
            if (rw > 0 && rh > 0) {
                double nx = rx / W;
                double nw = rw / W;
                double nh = rh / H;
                double ny = 1.0 - (ry + rh) / H; // flip Y
                request.regionOfInterest = CGRectMake(MAX(0, nx), MAX(0, ny), MIN(1, nw), MIN(1, nh));
            }
        }

        // Downsample large captures before OCR (longest edge cap). Speeds up Vision on
        // high-res iPad screens; coordinates still map back via the logical image.size.
        CGImageRef ocrImage = image.CGImage;
        CGImageRef downsampled = OCRCreateDownsampled(image.CGImage, 1600.0);
        if (downsampled) ocrImage = downsampled;

        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:ocrImage options:@{}];
        NSError *performError = nil;
        BOOL ok = [handler performRequests:@[request] error:&performError];

        // iOS 14's Vision can fail the accurate recognition level with an internal error
        // ("VNRecognizeTextRequest produced an internal error"). Fall back to the fast level
        // once so OCR still returns results instead of failing outright.
        if ((!ok || visionError) && !fast) {
            OCR_LOG(@"accurate failed (%@), retrying with fast level",
                    (performError ?: visionError).localizedDescription ?: @"?");
            observations = nil; visionError = nil;
            VNRecognizeTextRequest *fastReq = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *req, NSError *err) {
                visionError = err;
                observations = (NSArray<VNRecognizedTextObservation *> *)req.results;
            }];
            fastReq.recognitionLevel = VNRequestTextRecognitionLevelFast;
            fastReq.usesLanguageCorrection = NO;
            fastReq.recognitionLanguages = request.recognitionLanguages;
            fastReq.regionOfInterest = request.regionOfInterest;
            VNImageRequestHandler *h2 = [[VNImageRequestHandler alloc] initWithCGImage:ocrImage options:@{}];
            performError = nil;
            ok = [h2 performRequests:@[fastReq] error:&performError];
        }

        if (downsampled) CGImageRelease(downsampled);
        if (!ok || visionError) {
            NSString *msg = (performError ?: visionError).localizedDescription ?: @"Vision OCR failed";
            if (error) *error = msg;
            OCR_LOG(@"failed: %@", msg);
            return nil;
        }

        NSMutableArray<NSDictionary *> *texts = [NSMutableArray array];
        for (VNRecognizedTextObservation *obs in observations) {
            VNRecognizedText *top = [[obs topCandidates:1] firstObject];
            if (!top) continue;
            double conf = top.confidence;
            if (conf < minConfidence) continue;

            NSString *str = top.string ?: @"";
            if (str.length == 0) continue;

            // boundingBox is normalized (0..1), origin bottom-left. Map to screen points.
            CGRect bb = obs.boundingBox;
            double x = bb.origin.x * W;
            double w = bb.size.width * W;
            double h = bb.size.height * H;
            double y = (1.0 - bb.origin.y - bb.size.height) * H; // flip Y to top-left origin

            int ix = (int)round(x), iy = (int)round(y);
            int iw = (int)round(w), ih = (int)round(h);

            [texts addObject:@{
                @"text": str,
                @"confidence": @(round(conf * 100) / 100.0),
                @"rect": @{@"x": @(ix), @"y": @(iy), @"width": @(iw), @"height": @(ih)},
                @"tap": @{@"x": @(ix + iw / 2), @"y": @(iy + ih / 2)}
            }];
        }

        OCR_LOG(@"ok count=%lu langs=%@", (unsigned long)texts.count, request.recognitionLanguages);
        return @{
            @"texts": texts,
            @"count": @(texts.count),
            @"screen": @{@"width": @((int)round(W)), @"height": @((int)round(H))}
        };
    }

    if (error) *error = @"OCR requires iOS 13 or later";
    return nil;
}

@end
