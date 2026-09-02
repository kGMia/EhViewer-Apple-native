//
//  WarningView.swift
//  ehviewer apple
//
//  18+ 内容警告页面 (对应 Android WarningScene)
//

import SwiftUI

/// 18+ 内容警告视图
/// 首次启动时显示，用户必须接受才能继续使用
struct WarningView: View {
    let onAccept: () -> Void
    let onReject: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // 警告图标
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.yellow)
                .padding(.bottom, 24)
            
            // 标题
            Text("内容警告")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 16)
            
            // 警告内容
            VStack(alignment: .leading, spacing: 12) {
                warningText("本应用可能包含成人内容（18+），包括但不限于：")
                    .fontWeight(.medium)
                
                VStack(alignment: .leading, spacing: 8) {
                    bulletPoint("成人向绘画和插图")
                    bulletPoint("裸露或性暗示内容")
                    bulletPoint("其他可能不适合未成年人的内容")
                }
                .padding(.leading, 8)
                
                warningText("继续使用本应用即表示您确认：")
                    .fontWeight(.medium)
                    .padding(.top, 8)
                
                VStack(alignment: .leading, spacing: 8) {
                    bulletPoint("您已年满 18 周岁")
                    bulletPoint("您所在地区法律允许访问此类内容")
                    bulletPoint("您自愿并知情地访问这些内容")
                }
                .padding(.leading, 8)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            
            Spacer()
            
            // 按钮区域
            VStack(spacing: 12) {
                Button(action: onAccept) {
                    Text("我已年满 18 周岁，同意继续")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                
                Button(action: onReject) {
                    Text("离开")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func warningText(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.primary)
    }
    
    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

#Preview {
    WarningView(
        onAccept: { print("Accepted") },
        onReject: { print("Rejected") }
    )
}
