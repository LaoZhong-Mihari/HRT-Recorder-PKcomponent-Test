//
//  LabReportParserSelfTests.swift
//  HRT-Recorder
//

#if DEBUG && LAB_REPORT_SELF_TESTS
import Foundation
import UIKit

@MainActor
enum LabReportImagePipelineSelfTest {
    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-RunLabImagePipelineSelfTest") else {
            return
        }

        let outcome = await LabReportExtractionPipeline.extract(
            from: [makeSyntheticReportImage()],
            sourceKind: .imageUpload,
            defaultHormone: .estradiol
        )
        var failures = LabReportSelfTestVerifier.verifyStandardSevenHormonePanel(outcome.report)
        if !outcome.report.institution.contains("曙光医院") {
            failures.append("institution \(outcome.report.institution.isEmpty ? "nil" : outcome.report.institution)")
        }

        if failures.isEmpty {
            NSLog("LAB_IMAGE_PIPELINE_SELF_TEST PASS analytes=%d institution=%@ collected=%@ reported=%@ status=%@",
                  outcome.report.analytes.count,
                  outcome.report.institution,
                  LabReportSelfTestVerifier.formatted(outcome.report.collectedAt),
                  outcome.report.reportedAt.map { LabReportSelfTestVerifier.formatted($0) } ?? "",
                  outcome.statusMessage ?? "")
        } else {
            NSLog("LAB_IMAGE_PIPELINE_SELF_TEST FAIL failures=%@ analytes=%@ institution=%@ status=%@",
                  failures.joined(separator: "; "),
                  LabReportSelfTestVerifier.analyteSummary(outcome.report),
                  outcome.report.institution,
                  outcome.statusMessage ?? "")
        }
    }

    private static func makeSyntheticReportImage() -> UIImage {
        let size = CGSize(width: 1200, height: 780)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            draw("上海中医药大学附属曙光医院（东部）检验报告单", at: CGPoint(x: 300, y: 28), size: 30, weight: .semibold)
            draw("检验项目", at: CGPoint(x: 60, y: 150), size: 20, weight: .semibold)
            draw("结果", at: CGPoint(x: 420, y: 150), size: 20, weight: .semibold)
            draw("参考范围", at: CGPoint(x: 610, y: 150), size: 20, weight: .semibold)
            draw("系统或方法学", at: CGPoint(x: 930, y: 150), size: 20, weight: .semibold)

            let rows = [
                ("雌二醇（E2）", "51", "40.37-161.48pmol/L", "i2000SR"),
                ("垂体泌乳素（PRL）", "168.12", "72.66-407.4mIU/L", "i2000SR"),
                ("促卵泡刺激素（FSH）", "2.07", "0.95-11.95IU/L", "i2000SR"),
                ("促黄体生成素（LH）", "2.09", "0.57-12.07IU/L", "i2000SR"),
                ("睾酮（T）", "7.11", "4.94-32.01nmol/L", "i2000SR"),
                ("孕酮（P）", "0.70", "0-0.64nmol/L", "i2000SR"),
                ("硫酸脱氢表雄酮（DHEA-S）", "13.49", "1.20-10.40µmol/L", "i2000SR")
            ]

            for (index, row) in rows.enumerated() {
                let y = 192 + CGFloat(index) * 48
                draw("\(row.0)    \(row.1)    \(row.2)    \(row.3)",
                     at: CGPoint(x: 60, y: y),
                     size: 21,
                     weight: .regular)
            }

            UIColor.black.setStroke()
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 40, y: 138))
            path.addLine(to: CGPoint(x: 1140, y: 138))
            path.move(to: CGPoint(x: 40, y: 178))
            path.addLine(to: CGPoint(x: 1140, y: 178))
            path.lineWidth = 1
            path.stroke()

            draw("采集时间: 2026-04-10 16:34:01", at: CGPoint(x: 60, y: 600), size: 20, weight: .regular)
            draw("接收时间: 2026-04-10 16:39:42", at: CGPoint(x: 420, y: 600), size: 20, weight: .regular)
            draw("报告时间: 2026-04-11 08:51:33", at: CGPoint(x: 60, y: 640), size: 20, weight: .regular)
            draw("打印时间: 2026-04-11 08:51:49", at: CGPoint(x: 420, y: 640), size: 20, weight: .regular)
        }
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: UIFont.Weight) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]
        text.draw(at: point, withAttributes: attributes)
    }
}

enum LabReportOCRFallbackSelfTest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-RunLabOCRFallbackSelfTest") else {
            return
        }

        verifyStandardOCRFixtures()
        verifyLeadingFlagArtifactCorrection()
        verifySparsePanelDoesNotInferMissingRows()
        verifySpecimenEvidenceBoundary()
        verifySplitLabelAfterValueRows()
        verifyEnglishReportRows()
        verifyPatientPortalCardLayoutRows()
        verifyInternationalCompactRows()
        verifyGenericInternationalOtherRows()
        verifyColumnOrderVariantRows()
        verifyAdministrativeHintNoiseDoesNotWin()
    }

    private static func verifyStandardOCRFixtures() {
        for (name, text) in [("upload", uploadOCRFixture), ("scan", scanOCRFixture)] {
            let report = HormoneLabResultParser.parseReport(
                text,
                sourceKind: .pastedText,
                defaultHormone: .estradiol
            )
            let failures = LabReportSelfTestVerifier.verifyStandardSevenHormonePanel(report)
            if failures.isEmpty {
                NSLog("LAB_OCR_FALLBACK_SELF_TEST PASS fixture=%@ analytes=%d collected=%@ reported=%@",
                      name,
                      report.analytes.count,
                      LabReportSelfTestVerifier.formatted(report.collectedAt),
                      report.reportedAt.map { LabReportSelfTestVerifier.formatted($0) } ?? "")
            } else {
                NSLog("LAB_OCR_FALLBACK_SELF_TEST FAIL fixture=%@ failures=%@ analytes=%@",
                      name,
                      failures.joined(separator: "; "),
                      LabReportSelfTestVerifier.analyteSummary(report))
            }
        }
    }

    private static func verifyLeadingFlagArtifactCorrection() {
        let report = HormoneLabResultParser.parseReport(
            leadingFlagArtifactFixture,
            sourceKind: .pastedText,
            defaultHormone: .estradiol
        )
        let expected: [(LabAnalyteKind, Double)] = [
            (.follicleStimulatingHormone, 36.0),
            (.progesterone, 0.70),
            (.dehydroepiandrosteroneSulfate, 13.49)
        ]
        let failures = expected.compactMap { kind, value -> String? in
            guard let observed = report.analytes.first(where: { $0.kind == kind })?.value else {
                return "missing \(kind.rawValue)"
            }
            return abs(observed - value) <= 0.001 ? nil : "\(kind.rawValue) \(observed) != \(value)"
        }

        if failures.isEmpty {
            NSLog("LAB_OCR_FLAG_ARTIFACT_SELF_TEST PASS")
        } else {
            NSLog("LAB_OCR_FLAG_ARTIFACT_SELF_TEST FAIL failures=%@ analytes=%@",
                  failures.joined(separator: "; "),
                  LabReportSelfTestVerifier.analyteSummary(report))
        }
    }

    private static func verifySparsePanelDoesNotInferMissingRows() {
        let report = HormoneLabResultParser.parseReport(
            sparsePanelFixture,
            sourceKind: .pastedText,
            defaultHormone: .estradiol
        )
        let forbidden: Set<LabAnalyteKind> = [.follicleStimulatingHormone, .luteinizingHormone]
        var failures = forbidden.compactMap { kind in
            report.analytes.contains(where: { $0.kind == kind }) ? "unexpected \(kind.rawValue)" : nil
        }

        let expected: [(LabAnalyteKind, Double, String)] = [
            (.prolactin, 33.76, "ng/mL"),
            (.estradiol, 69.01, "pg/mL"),
            (.testosterone, 0.66, "nmol/L")
        ]
        for (kind, value, unit) in expected {
            guard let analyte = report.analytes.first(where: { $0.kind == kind }) else {
                failures.append("missing \(kind.rawValue)")
                continue
            }
            if abs((analyte.value ?? .nan) - value) > 0.001 {
                failures.append("\(kind.rawValue) value \(analyte.value.map { String($0) } ?? "nil") != \(value)")
            }
            if analyte.unitSymbol != unit {
                failures.append("\(kind.rawValue) unit \(analyte.unitSymbol) != \(unit)")
            }
        }

        if failures.isEmpty {
            NSLog("LAB_OCR_SPARSE_PANEL_SELF_TEST PASS")
        } else {
            NSLog("LAB_OCR_SPARSE_PANEL_SELF_TEST FAIL failures=%@ analytes=%@",
                  failures.joined(separator: "; "),
                  LabReportSelfTestVerifier.analyteSummary(report))
        }
    }

    private static func verifySpecimenEvidenceBoundary() {
        let corruptedReport = HormoneLabResultParser.parseReport(
            corruptedSpecimenFixture,
            sourceKind: .pastedText,
            defaultHormone: .estradiol
        )
        var failures: [String] = []
        if !corruptedReport.specimen.isEmpty {
            failures.append("corrupted specimen accepted as \(corruptedReport.specimen)")
        }

        let ungrounded = LabReportFieldSanitizer.groundedSpecimen(
            "serum",
            in: "Serum estradiol level was measured today."
        )
        if !ungrounded.isEmpty {
            failures.append("non-field serum accepted")
        }

        let grounded = LabReportFieldSanitizer.groundedSpecimen(
            "serum",
            in: "Specimen: serum"
        )
        if grounded.localizedCaseInsensitiveCompare("serum") != .orderedSame {
            failures.append("explicit specimen field rejected")
        }

        if failures.isEmpty {
            NSLog("LAB_OCR_SPECIMEN_BOUNDARY_SELF_TEST PASS")
        } else {
            NSLog("LAB_OCR_SPECIMEN_BOUNDARY_SELF_TEST FAIL failures=%@", failures.joined(separator: "; "))
        }
    }

    private static func verifyEnglishReportRows() {
        let report = HormoneLabResultParser.parseReport(
            englishReportFixture,
            sourceKind: .pastedText,
            defaultHormone: .estradiol
        )
        let expected: [(LabAnalyteKind, Double, String)] = [
            (.estradiol, 82.0, "pg/mL"),
            (.testosterone, 24.0, "ng/dL"),
            (.prolactin, 13.2, "ng/mL"),
            (.follicleStimulatingHormone, 5.6, "IU/L"),
            (.luteinizingHormone, 4.8, "IU/L"),
            (.progesterone, 0.4, "ng/mL")
        ]
        var failures: [String] = []
        for (kind, value, unit) in expected {
            guard let analyte = report.analytes.first(where: { $0.kind == kind }) else {
                failures.append("missing \(kind.rawValue)")
                continue
            }
            if abs((analyte.value ?? .nan) - value) > 0.001 {
                failures.append("\(kind.rawValue) value \(analyte.value.map { String($0) } ?? "nil") != \(value)")
            }
            if analyte.unitSymbol != unit {
                failures.append("\(kind.rawValue) unit \(analyte.unitSymbol) != \(unit)")
            }
        }

        if failures.isEmpty {
            NSLog("LAB_OCR_ENGLISH_REPORT_SELF_TEST PASS")
        } else {
            NSLog("LAB_OCR_ENGLISH_REPORT_SELF_TEST FAIL failures=%@ analytes=%@",
                  failures.joined(separator: "; "),
                  LabReportSelfTestVerifier.analyteSummary(report))
        }
    }

    private static func verifySplitLabelAfterValueRows() {
        let report = HormoneLabResultParser.parseReport(
            splitLabelAfterValueFixture,
            sourceKind: .pastedText,
            defaultHormone: .estradiol
        )
        let expected: [(LabAnalyteKind, Double, String)] = [
            (.prolactin, 33.76, "ng/mL"),
            (.estradiol, 69.01, "pg/mL"),
            (.testosterone, 0.66, "nmol/L")
        ]
        var failures = LabReportSelfTestVerifier.verifyExpectedAnalytes(report, expected: expected)
        let forbidden: Set<LabAnalyteKind> = [.follicleStimulatingHormone, .luteinizingHormone]
        failures.append(contentsOf: forbidden.compactMap { kind in
            report.analytes.contains(where: { $0.kind == kind }) ? "unexpected \(kind.rawValue)" : nil
        })

        if failures.isEmpty {
            NSLog("LAB_OCR_SPLIT_LABEL_SELF_TEST PASS")
        } else {
            NSLog("LAB_OCR_SPLIT_LABEL_SELF_TEST FAIL failures=%@ analytes=%@",
                  failures.joined(separator: "; "),
                  LabReportSelfTestVerifier.analyteSummary(report))
        }
    }

    private static func verifyPatientPortalCardLayoutRows() {
        let report = HormoneLabResultParser.parseReport(
            patientPortalCardFixture,
            sourceKind: .pastedText,
            defaultHormone: .estradiol
        )
        let expected: [(LabAnalyteKind, Double, String)] = [
            (.estradiol, 82.0, "pg/mL"),
            (.testosterone, 24.0, "ng/dL"),
            (.prolactin, 13.2, "ng/mL"),
            (.follicleStimulatingHormone, 5.6, "IU/L"),
            (.luteinizingHormone, 4.8, "IU/L"),
            (.progesterone, 0.4, "ng/mL")
        ]
        var failures = LabReportSelfTestVerifier.verifyExpectedAnalytes(report, expected: expected)
        if LabReportSelfTestVerifier.formatted(report.collectedAt) != "2026-06-12 08:10" {
            failures.append("collectedAt \(LabReportSelfTestVerifier.formatted(report.collectedAt))")
        }
        let reportedText = report.reportedAt.map { LabReportSelfTestVerifier.formatted($0) }
        if reportedText != "2026-06-13 12:22" {
            failures.append("reportedAt \(reportedText ?? "nil")")
        }

        if failures.isEmpty {
            NSLog("LAB_OCR_PORTAL_CARD_SELF_TEST PASS")
        } else {
            NSLog("LAB_OCR_PORTAL_CARD_SELF_TEST FAIL failures=%@ analytes=%@",
                  failures.joined(separator: "; "),
                  LabReportSelfTestVerifier.analyteSummary(report))
        }
    }

    private static func verifyInternationalCompactRows() {
        let report = HormoneLabResultParser.parseReport(
            internationalCompactFixture,
            sourceKind: .pastedText,
            defaultHormone: .estradiol
        )
        let expected: [(LabAnalyteKind, Double, String)] = [
            (.estradiol, 301.5, "pmol/L"),
            (.testosterone, 0.9, "nmol/L"),
            (.prolactin, 420.0, "mIU/L"),
            (.follicleStimulatingHormone, 6.1, "IU/L"),
            (.luteinizingHormone, 3.4, "IU/L"),
            (.progesterone, 1.2, "nmol/L")
        ]
        let failures = LabReportSelfTestVerifier.verifyExpectedAnalytes(report, expected: expected)

        if failures.isEmpty {
            NSLog("LAB_OCR_INTERNATIONAL_COMPACT_SELF_TEST PASS")
        } else {
            NSLog("LAB_OCR_INTERNATIONAL_COMPACT_SELF_TEST FAIL failures=%@ analytes=%@",
                  failures.joined(separator: "; "),
                  LabReportSelfTestVerifier.analyteSummary(report))
        }
    }

    private static func verifyColumnOrderVariantRows() {
        let report = HormoneLabResultParser.parseReport(
            columnOrderVariantFixture,
            sourceKind: .pastedText,
            defaultHormone: .estradiol
        )
        let expected: [(LabAnalyteKind, Double, String)] = [
            (.estradiol, 154.0, "pg/mL"),
            (.testosterone, 38.0, "ng/dL"),
            (.prolactin, 11.0, "ng/mL"),
            (.follicleStimulatingHormone, 7.2, "mIU/mL"),
            (.luteinizingHormone, 5.1, "mIU/mL")
        ]
        let failures = LabReportSelfTestVerifier.verifyExpectedAnalytes(report, expected: expected)

        if failures.isEmpty {
            NSLog("LAB_OCR_COLUMN_ORDER_SELF_TEST PASS")
        } else {
            NSLog("LAB_OCR_COLUMN_ORDER_SELF_TEST FAIL failures=%@ analytes=%@",
                  failures.joined(separator: "; "),
                  LabReportSelfTestVerifier.analyteSummary(report))
        }
    }

    private static func verifyGenericInternationalOtherRows() {
        let report = HormoneLabResultParser.parseReport(
            genericInternationalFixture,
            sourceKind: .pastedText,
            defaultHormone: .estradiol
        )
        let expected: [(String, Double, String)] = [
            ("TSH", 2.10, "mIU/L"),
            ("Glukose", 5.4, "mmol/L"),
            ("Ferritin", 88.0, "ng/mL"),
            ("HbA1c", 5.4, "%"),
            ("Leukozyten", 6.8, "10^9/L"),
            ("25-OH Vitamin D", 32.0, "ng/mL")
        ]
        var failures: [String] = []
        for (name, value, unit) in expected {
            guard let analyte = report.analytes.first(where: { $0.kind == .other && $0.displayName == name }) else {
                failures.append("missing \(name)")
                continue
            }
            if abs((analyte.value ?? .nan) - value) > 0.001 {
                failures.append("\(name) value \(analyte.value.map { String($0) } ?? "nil") != \(value)")
            }
            if analyte.unitSymbol != unit {
                failures.append("\(name) unit \(analyte.unitSymbol) != \(unit)")
            }
        }
        let reportedText = report.reportedAt.map { LabReportSelfTestVerifier.formatted($0) }
        if reportedText != "2026-06-14 12:00" {
            failures.append("reportedAt \(reportedText ?? "nil")")
        }

        if failures.isEmpty {
            NSLog("LAB_OCR_GENERIC_INTERNATIONAL_SELF_TEST PASS")
        } else {
            NSLog("LAB_OCR_GENERIC_INTERNATIONAL_SELF_TEST FAIL failures=%@ analytes=%@",
                  failures.joined(separator: "; "),
                  LabReportSelfTestVerifier.analyteSummary(report))
        }
    }

    private static let genericInternationalFixture = """
    Klinikum Berlin Laborbefund
    Abnahme: 14.06.2026 07:30
    Befunddatum: 14.06.2026 12:00
    Analyse Ergebnis Einheit Referenzbereich
    TSH 2,10 mIU/L 0,27-4,20
    Glukose 5,4 mmol/L 3,9-5,6
    Ferritin 88 ng/mL 30-400
    HbA1c 5,4 % 4,0-5,6
    Leukozyten 6,8 10^9/L 4,0-10,0
    25-OH Vitamin D 32 ng/mL 20-50
    """

    private static func verifyAdministrativeHintNoiseDoesNotWin() {
        let report = HormoneLabResultParser.parseReport(
            administrativeHintNoiseFixture,
            sourceKind: .pastedText,
            defaultHormone: .estradiol
        )
        let expected: [(LabAnalyteKind, Double, String)] = [
            (.prolactin, 33.76, "ng/mL"),
            (.estradiol, 69.01, "pg/mL"),
            (.testosterone, 0.66, "nmol/L")
        ]
        let failures = LabReportSelfTestVerifier.verifyExpectedAnalytes(report, expected: expected)

        if failures.isEmpty {
            NSLog("LAB_OCR_ADMIN_HINT_NOISE_SELF_TEST PASS")
        } else {
            NSLog("LAB_OCR_ADMIN_HINT_NOISE_SELF_TEST FAIL failures=%@ analytes=%@",
                  failures.joined(separator: "; "),
                  LabReportSelfTestVerifier.analyteSummary(report))
        }
    }

    private static let uploadOCRFixture = """
    SGH-QR-316/A
    FE 10 #10
    .... 5 0016829748 45:23
    # 9: 5604106568
    0: 193
    MA (B2) 51.00 40.37-161. 48pmol/L 12000SR
    168. 12 72.66-407.4mIU/L i2000SR
    2.07 0.95-11.95IV/L 12000SR
    2.09 0.57-12.07IU/L i2000SR
    · (T) 7.11 4.94-32.01mmol/L 12000SR
    0. 70 0-0. 64mmo1/L 12000SR
    13.49 1.20-10.40wmol/L i2000SR
    FBJ:2026-04-10 16:34:01 AJi: 2026-04-10 16:39:42 12Atie: 2026-04-11 08:51:33 #TEB: 2026-04-11 08:51:49
    12325: 3 +
    """

    private static let scanOCRFixture = """
    ********•SGH-QR-316/A L (B)
    _ 528
    5 0016829748
    1 1:99 772:5604106568
    : 193
    51.00 40. 37-161. 48pmol/L i2000SR
    E (PRL) 168. 12 72.66-407.4mIU/L
    i2000SR
    (FS) 2.07 0.95-11. 95IV/L i2000SR
    2. 09 0. 57-12.07IU/L i200SR
    FAN (I) 7.11 4.94-32.01nmol/L i2000SR
    FAR (P) 0. 70 0-0. 64nmol/L 12000SR
    13. 49 1.20-10. 40umol/L 12000SR
    FR:2026-04-10 16:34:01 Ati: 2026-04-10 16:39:42 RAfia]:2026-04-11 08:51:33 #E]:2026-04-1108:51:49
    ‡ : ‡ 1 , ¡ ‡ ##: 351299
    """

    private static let leadingFlagArtifactFixture = """
    上海中医药大学附属曙光医院（东部）检验报告单
    检验项目 结果 标志 参考范围 系统或方法学
    雌二醇（E2） 51.00 40.37-161.48pmol/L i2000SR
    垂体泌乳素（PRL） 168.12 72.66-407.4mIU/L i2000SR
    促卵泡刺激素（FSH） 136 0.95-11.95IU/L i2000SR
    促黄体生成素（LH） 2.09 0.57-12.07IU/L i2000SR
    睾酮（T） 7.11 4.94-32.01nmol/L i2000SR
    孕酮（P） 10.70 0-0.64nmol/L i2000SR
    硫酸脱氢表雄酮（DHEA-S） 113.49 1.20-10.40µmol/L i2000SR
    采集时间: 2026-04-10 16:34:01 报告时间: 2026-04-11 08:51:33
    """

    private static let sparsePanelFixture = """
    项目 结果 参考范围 单位
    1 PRL 垂体泌乳素 1 33.76 2.7-15.2 ng/ml
    2 E2 雌二醇 ↑69.01 11.3-43.2 pg/m1
    3 Testo •0.66 Tanner5期：6.5-30.6 nmol/L
    审核 检验 核对
    """

    private static let corruptedSpecimenFixture = """
    华中科技大学同济医学院附属协和医院核医学科报告单
    标本种类: 血消
    项目 结果 参考范围 单位
    Testo 睾酮 0.66 6.5-30.6 nmol/L
    """

    private static let splitLabelAfterValueFixture = """
    项目 结果 参考范围 单位
    PRL 垂体泌乳素 ↑ 33.76 2.7-15.2 ng/ml [analyte:prolactin Prolactin]
    1
    ↑69.01 11.3-43.2 pg/m1
    2 E2 雌二醇 [analyte:estradiol Estradiol]
    ¥0.66 Tanner5期：6.5-30.6 nmol/L
    3 Testo 睾酮 [analyte:testosterone Testosterone]
    审核 检验 核对
    """

    private static let administrativeHintNoiseFixture = """
    项目
    1 PRL 垂体泌乳素 [analyte:prolactin Prolactin]
    2 E2 [analyte:estradiol Estradiol]
    Testo 率間 [analyte:testosterone Testosterone]
    结果
    + 33.76
    169.01
    10.66
    参考花围
    2.7-15.2
    11.3-43.2
    Tanners期：6.5-30.6
    标本编号： [analyte:testosterone Testosterone]
    送检医生： [analyte:testosterone Testosterone]
    临床诊断：200.001| [analyte:testosterone Testosterone]
    单位
    ng/ml
    pg/ml
    nmol/L
    备注： 单位
    项目 结果 参考范围
    PRL 垂体泌乳素 ↑ 33.76 2.7-15.2 ng/ml [analyte:prolactin Prolactin]
    1
    ↑69.01 11.3-43.2 pg/m1
    2 E2 雌二醇 [analyte:estradiol Estradiol]
    ¥0.66 Tanner5期：6.5-30.6 nmol/L
    3 Testo 睾酮 [analyte:testosterone Testosterone]
    """

    private static let englishReportFixture = """
    Example Regional Medical Center
    Laboratory Results
    Collection Date: 2026-04-10 09:12
    Result Date: 2026-04-11 14:05
    Estradiol, Sensitive 82 pg/mL Reference Range 15-350
    Testosterone, Total 24 ng/dL Reference Range 8-60
    Prolactin 13.2 ng/mL Reference Range 4.8-23.3
    Follicle Stimulating Hormone (FSH) 5.6 IU/L Reference Range 1.5-12.4
    Luteinising Hormone (LH) 4.8 IU/L Reference Range 1.7-8.6
    Progesterone 0.4 ng/mL Reference Range 0.1-0.8
    """

    private static let patientPortalCardFixture = """
    Patient Portal
    Lab Results
    Collected Jun 12, 2026 08:10 AM
    Reported Jun 13, 2026 12:22 PM
    Estradiol
    Value
    82
    Unit
    pg/mL
    Reference Range
    15 - 350
    Testosterone, Total
    Result
    24
    ng/dL
    Reference Interval
    8 - 60
    Prolactin
    Result 13.2
    Unit ng/mL
    Reference Range 4.8 - 23.3
    Follicle Stimulating Hormone
    5.6
    IU/L
    1.5 - 12.4
    Luteinising Hormone
    4.8 IU/L
    1.7 - 8.6
    Progesterone
    0.4 ng/mL
    0.1 - 0.8
    """

    private static let internationalCompactFixture = """
    Endocrinology blood results
    Sample collected: 12 Jun 2026 07:45
    Report date: 13 Jun 2026 18:05
    Test Result Units Reference interval
    Oestradiol 301,5 pmol/L 100,0 - 500,0
    Total testosterone 0,9 nmol/L 0,3 - 1,7
    Prolactin 420 mIU/L 102 - 496
    Follicle stimulating hormone 6,1 IU/L 1,7 - 8,6
    Luteinising hormone 3,4 IU/L 1,0 - 11,4
    Progesterone 1,2 nmol/L 0,0 - 5,0
    """

    private static let columnOrderVariantFixture = """
    Lab Results
    Specimen: Serum
    Date Collected 06/12/2026 09:30
    Date Reported 06/13/2026 15:40
    TEST NAME RESULT UNITS REFERENCE INTERVAL
    Estradiol, Ultrasensitive 154 pg/mL 15-350
    Testosterone, Total, MS 38 ng/dL 8-60
    Prolactin 11.0 ng/mL 4.8-23.3
    FSH 7.2 mIU/mL 1.5-12.4
    LH 5.1 mIU/mL 1.7-8.6
    """
}

private enum LabReportSelfTestVerifier {
    static func verifyExpectedAnalytes(
        _ report: LabReport,
        expected: [(LabAnalyteKind, Double, String)]
    ) -> [String] {
        var failures: [String] = []
        for (kind, value, unit) in expected {
            guard let analyte = report.analytes.first(where: { $0.kind == kind }) else {
                failures.append("missing \(kind.rawValue)")
                continue
            }
            if abs((analyte.value ?? .nan) - value) > 0.001 {
                failures.append("\(kind.rawValue) value \(analyte.value.map { String($0) } ?? "nil") != \(value)")
            }
            if analyte.unitSymbol != unit {
                failures.append("\(kind.rawValue) unit \(analyte.unitSymbol) != \(unit)")
            }
        }
        return failures
    }

    static func verifyStandardSevenHormonePanel(_ report: LabReport) -> [String] {
        var failures: [String] = []
        let expected: [(LabAnalyteKind, Double, String)] = [
            (.estradiol, 51.00, "pmol/L"),
            (.prolactin, 168.12, "mIU/L"),
            (.follicleStimulatingHormone, 2.07, "IU/L"),
            (.luteinizingHormone, 2.09, "IU/L"),
            (.testosterone, 7.11, "nmol/L"),
            (.progesterone, 0.70, "nmol/L"),
            (.dehydroepiandrosteroneSulfate, 13.49, "µmol/L")
        ]

        failures.append(contentsOf: verifyExpectedAnalytes(report, expected: expected))

        if formatted(report.collectedAt) != "2026-04-10 16:34" {
            failures.append("collectedAt \(formatted(report.collectedAt))")
        }
        let reportedText = report.reportedAt.map { formatted($0) }
        if reportedText != "2026-04-11 08:51" {
            failures.append("reportedAt \(reportedText ?? "nil")")
        }

        return failures
    }

    static func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func analyteSummary(_ report: LabReport) -> String {
        report.analytes
            .map { analyte -> String in
                let valueText = analyte.value.map { String($0) } ?? "nil"
                return "\(analyte.kind.rawValue)=\(valueText) \(analyte.unitSymbol) source=\(analyte.sourceLine ?? "")"
            }
            .joined(separator: ", ")
    }
}
#endif
