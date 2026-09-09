//
//  LogExportView.swift
//  ehviewer apple
//
//  日志导出视图 — 从 SettingsView 连点版本号 5 次触发
//

import SwiftUI
import UniformTypeIdentifiers
import EhSettings

private nonisolated struct DiagnosticLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var data = Data()

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct LogExportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logContent: String = AppLocalization.localized("加载中...")
    @State private var logSize: String = ""
    @State private var logFiles: [URL] = []
    @State private var isExporting = false
    @State private var exportDocument = DiagnosticLogDocument()
    @State private var exportFilename = "EhViewer-Diagnostics"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 状态栏
                HStack {
                    Label("日志文件: \(logFiles.count) 个", systemImage: "doc.text")
                    Spacer()
                    Text(logSize)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)

                // 日志内容预览
                ScrollView {
                    Text(logContent)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("诊断日志")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        exportLog()
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                    .disabled(logFiles.isEmpty)

                    Button(role: .destructive) {
                        LogManager.shared.clearLogs()
                        loadLogs()
                    } label: {
                        Label("清除", systemImage: "trash")
                    }
                }
            }
            .task { loadLogs() }
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: .plainText,
                defaultFilename: exportFilename
            ) { result in
                if case .failure(let error) = result {
                    // Cancellation is intentionally silent; genuine exporter
                    // failures still flow through the app-wide error surface.
                    let nsError = error as NSError
                    guard nsError.code != NSUserCancelledError else { return }
                    ErrorHandler.shared.handle(error, context: "LogExport")
                }
            }
        }
    }

    private func loadLogs() {
        logFiles = LogManager.shared.allLogFiles()
        let size = LogManager.shared.totalLogSize()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        logSize = formatter.string(fromByteCount: size)

        if logFiles.isEmpty {
            logContent = AppLocalization.localized("(暂无日志)")
            return
        }

        // 只加载最新的日志文件内容 (最多 200 行)
        if let latest = logFiles.first,
           let content = try? String(contentsOf: latest, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n")
            if lines.count > 200 {
                logContent = AppLocalization.format("… (共 %lld 行, 显示最新 200 行)\n\n", lines.count)
                    + lines.suffix(200).joined(separator: "\n")
            } else {
                logContent = content
            }
        } else {
            logContent = AppLocalization.localized("(无法读取日志)")
        }
    }

    private func exportLog() {
        guard let url = LogManager.shared.exportCombinedLog() else { return }
        do {
            exportDocument = DiagnosticLogDocument(data: try Data(contentsOf: url))
            exportFilename = url.deletingPathExtension().lastPathComponent
            isExporting = true
        } catch {
            ErrorHandler.shared.handle(error, context: "LogExportPreparation")
        }
    }
}
