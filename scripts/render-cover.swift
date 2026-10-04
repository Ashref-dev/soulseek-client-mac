#!/usr/bin/env swift
// Renders the README cover (docs/cover.jpg) at 2560x1280.
// Usage: bash scripts/build-app.sh && swift scripts/render-cover.swift dist/Arpeggio.app docs/cover.jpg

import SwiftUI
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let icon = NSImage(contentsOfFile: arguments[1] + "/Contents/Resources/AppIcon.icns") else {
    FileHandle.standardError.write(Data("usage: render-cover.swift <Arpeggio.app> <output.jpg>\n".utf8))
    exit(64)
}

let violet = Color(red: 0.53, green: 0.45, blue: 0.88)

struct Pill: View {
    let symbol: String
    let text: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 17, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.white.opacity(0.1), in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
    }
}

struct PlayerCard: View {
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Color(red: 0.95, green: 0.55, blue: 0.4), Color(red: 0.55, green: 0.25, blue: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 64, height: 64)
                .overlay(Image(systemName: "waveform").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Glass Notes").font(.system(size: 19, weight: .semibold)).fixedSize()
                    Text("PREVIEW").font(.system(size: 10, weight: .bold)).tracking(0.8)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(violet.opacity(0.25), in: .capsule).foregroundStyle(violet)
                }
                Text("Studio Fixture · Night Sessions").font(.system(size: 14)).opacity(0.65).fixedSize()
                HStack(spacing: 8) {
                    Capsule().fill(.white.opacity(0.15)).frame(width: 170, height: 5)
                        .overlay(alignment: .leading) { Capsule().fill(violet).frame(width: 110, height: 5) }
                    Text("1:42").font(.system(size: 12).monospacedDigit()).opacity(0.6)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            Image(systemName: "pause.circle.fill").font(.system(size: 32)).foregroundStyle(violet)
            Label("Download", systemImage: "arrow.down.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(violet, in: .capsule)
        }
        .padding(18)
        .frame(width: 540)
        .background(Color(white: 0.11).opacity(0.92), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
    }
}

struct ResultsCard: View {
    let rows: [(String, String, String)] = [
        ("01 Glass Notes.flac", "24-bit / 96 kHz", "4:12"),
        ("02 Paper Lanterns.flac", "24-bit / 96 kHz", "3:48"),
        ("03 Low Tide.flac", "24-bit / 96 kHz", "5:01"),
        ("04 Northern Line.flac", "24-bit / 96 kHz", "3:27"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "person.crop.circle").opacity(0.7)
                Text("studio-fixture").font(.system(size: 16, weight: .semibold))
                Text("1 folder · 4 files · 212 MB").font(.system(size: 13)).opacity(0.55)
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .padding(.bottom, 12)
            ForEach(rows, id: \.0) { row in
                HStack {
                    Image(systemName: row.0.hasPrefix("01") ? "pause.circle.fill" : "music.note")
                        .foregroundStyle(row.0.hasPrefix("01") ? violet : .white.opacity(0.5))
                        .frame(width: 22)
                    Text(row.0).font(.system(size: 15))
                    Spacer()
                    Text(row.1).font(.system(size: 13)).opacity(0.55)
                    Text(row.2).font(.system(size: 13).monospacedDigit()).opacity(0.55).frame(width: 44, alignment: .trailing)
                }
                .padding(.vertical, 9).padding(.horizontal, 8)
                .background(row.0.hasPrefix("01") ? .white.opacity(0.08) : .clear, in: .rect(cornerRadius: 8))
            }
        }
        .padding(20)
        .frame(width: 540)
        .background(Color(white: 0.09).opacity(0.9), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
    }
}

struct Cover: View {
    let icon: NSImage
    var body: some View {
        HStack(spacing: 50) {
            VStack(alignment: .leading, spacing: 26) {
                Image(nsImage: icon).resizable().frame(width: 150, height: 150)
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Arpeggio").font(.system(size: 76, weight: .bold, design: .rounded))
                    Text("A native Soulseek client for macOS.\nSearch, preview, download and share.")
                        .font(.system(size: 26, weight: .medium)).opacity(0.75)
                        .lineSpacing(4)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Pill(symbol: "play.circle", text: "Stream before you download")
                        Pill(symbol: "menubar.arrow.up.rectangle", text: "Lives in the menu bar")
                    }
                    HStack(spacing: 10) {
                        Pill(symbol: "externaldrive.badge.wifi", text: "Easy sharing")
                        Pill(symbol: "swift", text: "100% Swift")
                        Pill(symbol: "arrow.triangle.2.circlepath", text: "Auto-updates")
                    }
                }
            }
            .frame(width: 540, alignment: .leading)
            VStack(spacing: 26) {
                ResultsCard().rotationEffect(.degrees(-2)).offset(x: 12)
                PlayerCard().rotationEffect(.degrees(1.5)).offset(x: -8)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 60)
        .frame(width: 1280, height: 640)
        .background {
            ZStack {
                LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.36), Color(red: 0.05, green: 0.04, blue: 0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(violet.opacity(0.45)).frame(width: 700).blur(radius: 160).offset(x: -380, y: -260)
                Circle().fill(Color(red: 0.95, green: 0.45, blue: 0.55).opacity(0.18)).frame(width: 600).blur(radius: 170).offset(x: 460, y: 300)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Cover(icon: icon))
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else {
        FileHandle.standardError.write(Data("Rendering failed\n".utf8)); exit(1)
    }
    do { try jpeg.write(to: URL(fileURLWithPath: arguments[2])) } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    print("Wrote \(arguments[2])")
}
