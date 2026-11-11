//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// Summarizes the counts that benchmark-count.sh produced as a Markdown comment.
//
// Usage: swift benchmark-report.swift <results-directory> <expected-tools> <base-sha> <head-sha> <swift-version> <run-url>
//
// The results directory holds one `<tool>_<build>.tsv` file per tool and build that finished,
// where the build is `base` or `head`. A tool in <expected-tools> (comma-separated) missing
// either file is listed as failed.
//
// A count is called lower or higher only when it moved by more than `minimumChangePercent` and by
// more than `spreadMultiple` times the variation between the repeats of either build. Instruction
// counts of the threaded tools vary a little between runs, and a change inside that variation says
// nothing about the code.

import Foundation

let minimumChangePercent = 0.25
let spreadMultiple = 3.0

struct ReportError: Error, CustomStringConvertible {
    var description: String
}

enum Build: String {
    case base
    case head
}

enum Metric: String, CaseIterable {
    case instructions
    case allocations

    var heading: String {
        switch self {
        case .instructions: "Instructions"
        case .allocations: "Allocations"
        }
    }
}

enum Verdict {
    case lower
    case higher
    case unchanged

    var symbol: String {
        switch self {
        case .lower: "🟢"
        case .higher: "🔴"
        case .unchanged: "➖"
        }
    }
}

/// The repeated counts of one metric for one build of one tool. It always holds at least one count.
struct Counts {
    private(set) var values: [Double]

    init(first: Double) {
        self.values = [first]
    }

    mutating func append(_ value: Double) {
        self.values.append(value)
    }

    var median: Double {
        let ordered = self.values.sorted()
        let middle = ordered.count / 2
        return ordered.count % 2 == 1 ? ordered[middle] : (ordered[middle - 1] + ordered[middle]) / 2
    }

    /// The difference between the largest and smallest repeat, as a percentage of the median.
    var spreadPercent: Double {
        let ordered = self.values.sorted()
        let median = self.median
        return median == 0 ? 0 : (ordered[ordered.count - 1] - ordered[0]) / median * 100
    }
}

struct Comparison {
    var base: Counts
    var head: Counts

    /// The change in the median as a percentage, or nil when the base is zero and the change has no scale.
    var changePercent: Double? {
        self.base.median == 0 ? nil : (self.head.median - self.base.median) / self.base.median * 100
    }

    var spreadPercent: Double {
        max(self.base.spreadPercent, self.head.spreadPercent)
    }

    var verdict: Verdict {
        guard let change = self.changePercent else {
            return self.head.median == 0 ? .unchanged : .higher
        }

        if abs(change) > max(minimumChangePercent, spreadMultiple * self.spreadPercent) {
            return change < 0 ? .lower : .higher
        }
        return .unchanged
    }

    var changeText: String {
        guard let change = self.changePercent else {
            return self.head.median == 0 ? percent(0) : "0 → \(abbreviated(self.head.median))"
        }

        return percent(change)
    }
}

struct MetricComparison {
    var metric: Metric
    var comparison: Comparison
}

/// `results[tool][build][metric]`.
typealias Results = [String: [Build: [Metric: Counts]]]

/// Parses `<metric>\t<repeat>\t<count>`. The repeat number is checked but not needed. Counts are
/// integers, so a count such as `nan` or `1e999` is rejected.
func parseLine(_ line: Substring) -> (metric: Metric, count: Double)? {
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.count == 3,
        let metric = Metric(rawValue: String(fields[0])),
        Int(fields[1]) != nil,
        let count = UInt64(fields[2])
    else {
        return nil
    }

    return (metric, Double(count))
}

/// Reads the results of every tool and build. A file with a malformed line is skipped with a warning,
/// so that tool is reported as failed and the others are still reported.
func loadResults(from resultsDirectory: String) throws -> Results {
    var results = Results()
    guard let enumerator = FileManager.default.enumerator(atPath: resultsDirectory) else {
        throw ReportError(description: "Cannot read the results directory \(resultsDirectory).")
    }

    let paths = enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".tsv") }.sorted()
    for path in paths {
        let name = String(path.dropLast(".tsv".count))
        guard let separator = name.lastIndex(of: "_"),
            let build = Build(rawValue: String(name[name.index(after: separator)...]))
        else {
            throw ReportError(description: "The file \(path) is not named <tool>_base.tsv or <tool>_head.tsv.")
        }

        let tool = String(name[..<separator])
        let contents = try String(contentsOfFile: "\(resultsDirectory)/\(path)", encoding: .utf8)
        var counts: [Metric: Counts] = [:]
        var malformedLine: Substring?
        for line in contents.split(separator: "\n") {
            guard let parsed = parseLine(line) else {
                malformedLine = line
                break
            }

            if counts[parsed.metric] == nil {
                counts[parsed.metric] = Counts(first: parsed.count)
            } else {
                counts[parsed.metric]?.append(parsed.count)
            }
        }

        if let malformedLine {
            FileHandle.standardError.write(Data("warning: ignoring \(path), which has a malformed line: \(malformedLine)\n".utf8))
            continue
        }
        results[tool, default: [:]][build] = counts
    }
    return results
}

func compare(_ results: Results, tool: String, metric: Metric) -> MetricComparison? {
    guard let base = results[tool]?[.base]?[metric],
        let head = results[tool]?[.head]?[metric]
    else {
        return nil
    }

    return MetricComparison(metric: metric, comparison: Comparison(base: base, head: head))
}

/// Returns a comparison for every metric, or nil if the tool lacks either build of any metric.
func compareMetrics(of tool: String, in results: Results) -> [MetricComparison]? {
    var comparisons: [MetricComparison] = []
    for metric in Metric.allCases {
        guard let comparison = compare(results, tool: tool, metric: metric) else {
            return nil
        }

        comparisons.append(comparison)
    }
    return comparisons
}

func percent(_ change: Double) -> String {
    String(format: "%+.2f%%", change).replacingOccurrences(of: "-", with: "−")
}

/// Returns the value abbreviated as 1.23 G, 45.6 M or 789 k, so the base and head of a change read side by side.
func abbreviated(_ value: Double) -> String {
    let scales: [(divisor: Double, suffix: String)] = [(1e9, "G"), (1e6, "M"), (1e3, "k")]
    // A value that would round up to 1000 of one unit is shown in the next unit.
    for scale in scales where value >= scale.divisor * 0.9995 {
        let scaled = value / scale.divisor
        let digits = scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2
        return "\(String(format: "%.\(digits)f", scaled)) \(scale.suffix)"
    }
    return String(format: "%.0f", value)
}

func renderDetails(tool: String, comparisons: [MetricComparison]) -> [String] {
    var lines = [
        "<details>",
        "<summary>\(tool)</summary>",
        "",
        "| | base | head | Δ | repeat spread | |",
        "| --- | ---: | ---: | ---: | ---: | :-: |",
    ]
    for entry in comparisons {
        let comparison = entry.comparison
        lines.append(
            "| \(entry.metric.rawValue) | \(abbreviated(comparison.base.median)) | \(abbreviated(comparison.head.median)) "
                + "| \(comparison.changeText) | \(String(format: "%.2f%%", comparison.spreadPercent)) | \(comparison.verdict.symbol) |"
        )
    }
    lines.append("")
    for entry in comparisons {
        let base = entry.comparison.base.values.map { String(format: "%.0f", $0) }.joined(separator: ", ")
        let head = entry.comparison.head.values.map { String(format: "%.0f", $0) }.joined(separator: ", ")
        lines.append("\(entry.metric.rawValue): base \(base); head \(head)  ")
    }
    lines += ["", "</details>", ""]
    return lines
}

func render(
    results: Results,
    expectedTools: [String],
    baseSHA: String,
    headSHA: String,
    swiftVersion: String,
    runURL: String
) -> String {
    let headings = Metric.allCases.map(\.heading)
    var summary = [
        "| Tool | \(headings.joined(separator: " | ")) |",
        "| --- |" + String(repeating: " ---: |", count: headings.count),
    ]
    var details: [String] = []
    var failed: [String] = []

    for tool in expectedTools {
        guard let comparisons = compareMetrics(of: tool, in: results) else {
            failed.append(tool)
            continue
        }

        let cells = comparisons.map { "\($0.comparison.changeText) \($0.comparison.verdict.symbol)" }
        summary.append("| \(tool) | \(cells.joined(separator: " | ")) |")
        details += renderDetails(tool: tool, comparisons: comparisons)
    }

    var lines = [
        "## Benchmark results",
        "",
        "`\(headSHA.prefix(12))` (this change) against `\(baseSHA.prefix(12))` (merge base), Swift \(swiftVersion), "
            + "[workflow run](\(runURL)). "
            + "Counts are the instructions executed and the heap allocations made by a short fixed workload under valgrind.",
        "",
    ]
    lines += summary
    lines += [
        "",
        "\(Verdict.lower.symbol) lower, \(Verdict.higher.symbol) higher, \(Verdict.unchanged.symbol) no change: "
            + "a change must exceed \(String(format: "%g", minimumChangePercent))% "
            + "and \(String(format: "%g", spreadMultiple)) times the variation between repeats of either build.",
        "",
    ]
    lines += details
    if !failed.isEmpty {
        lines += ["No results for: " + failed.map { "`\($0)`" }.joined(separator: ", ") + ". See the workflow run.", ""]
    }
    return lines.joined(separator: "\n")
}

let arguments = CommandLine.arguments
if arguments.count != 7 {
    FileHandle.standardError.write(
        Data("usage: benchmark-report.swift <results-directory> <expected-tools> <base-sha> <head-sha> <swift-version> <run-url>\n".utf8)
    )
    exit(2)
}

do {
    let results = try loadResults(from: arguments[1])
    let expectedTools = arguments[2].split(separator: ",").map(String.init)
    print(
        render(
            results: results,
            expectedTools: expectedTools,
            baseSHA: arguments[3],
            headSHA: arguments[4],
            swiftVersion: arguments[5],
            runURL: arguments[6]
        ),
        terminator: ""
    )
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
