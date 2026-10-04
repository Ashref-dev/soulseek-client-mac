#!/usr/bin/env swift
// Renders the README cover (docs/cover.jpg), 4:3 at 2880x2160.
// Usage: bash scripts/build-app.sh && swift scripts/render-cover.swift dist/Soulseek-Arpeggio.app docs/cover.jpg

import SwiftUI
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let icon = NSImage(contentsOfFile: arguments[1] + "/Contents/Resources/AppIcon.icns") else {
    FileHandle.standardError.write(Data("usage: render-cover.swift <Soulseek-Arpeggio.app> <output.jpg>\n".utf8))
    exit(64)
}

let violet = Color(red: 0.53, green: 0.45, blue: 0.88)
let lavender = Color(red: 0.78, green: 0.72, blue: 1)
let panel = Color(red: 0.11, green: 0.10, blue: 0.15)
let sidebar = Color(red: 0.15, green: 0.13, blue: 0.21)

struct Pill: View {
    let symbol: String
    let text: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 19, weight: .medium))
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(.white.opacity(0.09), in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
    }
}

struct SidebarRow: View {
    let symbol: String
    let title: String
    var selected = false
    var badge: String? = nil
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(selected ? .white : lavender)
            Text(title)
            Spacer()
            if let badge { Text(badge).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 2).background(.white.opacity(0.12), in: .capsule) }
        }
        .font(.system(size: 15, weight: selected ? .semibold : .regular))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? violet.opacity(0.55) : .clear, in: .rect(cornerRadius: 8))
    }
}

struct Track: View {
    let number: Int
    let title: String
    let length: String
    var playing = false
    var downloaded = false
    var quality = "24-bit / 96 kHz"
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: playing ? "pause.circle.fill" : downloaded ? "checkmark.circle.fill" : "music.note")
                .foregroundStyle(playing ? violet : downloaded ? .green : .white.opacity(0.45))
                .frame(width: 22)
            Text(String(format: "%02d  %@.flac", number, title)).fontWeight(playing ? .semibold : .regular)
            Spacer()
            Text(quality).opacity(0.5)
            Text(length).monospacedDigit().opacity(0.5).frame(width: 44, alignment: .trailing)
        }
        .font(.system(size: 15))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(playing ? .white.opacity(0.08) : .clear, in: .rect(cornerRadius: 8))
    }
}

struct AppWindow: View {
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                        Circle().fill($0).frame(width: 13, height: 13)
                    }
                }
                .padding(.bottom, 18).padding(.leading, 4)
                Text("Discover").font(.system(size: 12, weight: .semibold)).opacity(0.45).padding(.leading, 10)
                SidebarRow(symbol: "magnifyingglass", title: "Search", selected: true)
                SidebarRow(symbol: "star", title: "Wishlist")
                SidebarRow(symbol: "folder", title: "Browse")
                Text("Transfers").font(.system(size: 12, weight: .semibold)).opacity(0.45).padding(.leading, 10).padding(.top, 10)
                SidebarRow(symbol: "arrow.down.circle", title: "Downloads", badge: "3")
                SidebarRow(symbol: "arrow.up.circle", title: "Uploads", badge: "2")
                Text("Library").font(.system(size: 12, weight: .semibold)).opacity(0.45).padding(.leading, 10).padding(.top, 10)
                SidebarRow(symbol: "externaldrive", title: "Shared Files")
                SidebarRow(symbol: "chart.bar.xaxis", title: "Statistics")
                Spacer()
                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        Circle().fill(LinearGradient(colors: [violet, violet.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 34, height: 34)
                            .overlay(Text("NS").font(.system(size: 13, weight: .semibold, design: .rounded)))
                        Circle().fill(.green).frame(width: 10, height: 10).overlay(Circle().strokeBorder(sidebar, lineWidth: 2))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("nightshift").font(.system(size: 14, weight: .semibold))
                        Text("Available").font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
            }
            .padding(16)
            .frame(width: 250)
            .frame(maxHeight: .infinity)
            .background(sidebar)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Search").font(.system(size: 20, weight: .bold))
                        Text("1,284 results from 37 people · live").font(.system(size: 13)).opacity(0.5)
                    }
                    Spacer()
                    Label("night sessions flac", systemImage: "magnifyingglass")
                        .font(.system(size: 14)).padding(.horizontal, 14).padding(.vertical, 8)
                        .frame(width: 280, alignment: .leading)
                        .background(.white.opacity(0.08), in: .capsule)
                }
                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
                HStack(spacing: 8) {
                    ForEach(["Lossless", "Any format", "Free slots"], id: \.self) { item in
                        Text(item).font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(item == "Lossless" ? violet.opacity(0.35) : .white.opacity(0.07), in: .capsule)
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 12)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).opacity(0.5)
                        Image(systemName: "person.crop.circle").opacity(0.7)
                        Text("studio-fixture").font(.system(size: 16, weight: .semibold))
                        Text("1 folder · 6 files · 318 MB").font(.system(size: 13)).opacity(0.5)
                        Spacer()
                        Text("11.9 MB/s").font(.system(size: 13)).opacity(0.5)
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .padding(.horizontal, 12).padding(.bottom, 6)
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).opacity(0.5)
                        Image(systemName: "opticaldisc").foregroundStyle(lavender)
                        Text("Night Sessions (2026)").font(.system(size: 15, weight: .medium))
                        Spacer()
                        Text("FLAC · 24-bit / 96 kHz · 38m").font(.system(size: 13)).opacity(0.5)
                        Image(systemName: "arrow.down.circle").foregroundStyle(violet)
                    }
                    .padding(.horizontal, 32).padding(.bottom, 4)
                    VStack(spacing: 0) {
                        Track(number: 1, title: "Glass Notes", length: "4:12", playing: true)
                        Track(number: 2, title: "Paper Lanterns", length: "3:48", downloaded: true)
                        Track(number: 3, title: "Low Tide", length: "5:01")
                        Track(number: 4, title: "Northern Line", length: "3:27")
                        Track(number: 5, title: "Afterglow", length: "6:10")
                    }
                    .padding(.leading, 30)
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).opacity(0.5)
                        Image(systemName: "person.crop.circle").opacity(0.7)
                        Text("vinyl-archive").font(.system(size: 16, weight: .semibold))
                        Text("2 folders · 14 files · 702 MB").font(.system(size: 13)).opacity(0.5)
                        Spacer()
                        Text("4.2 MB/s").font(.system(size: 13)).opacity(0.5)
                        Image(systemName: "clock").foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).opacity(0.5)
                        Image(systemName: "opticaldisc").foregroundStyle(lavender)
                        Text("Night Sessions (Deluxe Edition)").font(.system(size: 15, weight: .medium))
                        Spacer()
                        Text("FLAC · 16-bit / 44.1 kHz · 52m").font(.system(size: 13)).opacity(0.5)
                        Image(systemName: "arrow.down.circle").foregroundStyle(violet)
                    }
                    .padding(.horizontal, 32).padding(.bottom, 4)
                    Track(number: 6, title: "Glass Notes (Live)", length: "5:34", quality: "16-bit / 44.1 kHz").padding(.leading, 30)
                }
                .padding(.horizontal, 10)
                Spacer(minLength: 0)
                HStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(LinearGradient(colors: [Color(red: 0.95, green: 0.55, blue: 0.4), Color(red: 0.55, green: 0.25, blue: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 54, height: 54)
                        .overlay(Image(systemName: "waveform").font(.system(size: 20, weight: .semibold)))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Glass Notes").font(.system(size: 16, weight: .semibold))
                            Text("PREVIEW").font(.system(size: 9, weight: .bold)).tracking(0.8)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(violet.opacity(0.3), in: .capsule).foregroundStyle(lavender)
                        }
                        Text("Studio Fixture · Night Sessions").font(.system(size: 13)).opacity(0.55)
                    }
                    .fixedSize()
                    Spacer()
                    HStack(spacing: 18) {
                        Image(systemName: "gobackward.15").opacity(0.6)
                        Image(systemName: "pause.circle.fill").font(.system(size: 34)).foregroundStyle(violet)
                        Image(systemName: "goforward.15").opacity(0.6)
                    }
                    .font(.system(size: 17))
                    HStack(spacing: 8) {
                        Text("1:42").font(.system(size: 12).monospacedDigit()).opacity(0.5)
                        Capsule().fill(.white.opacity(0.14)).frame(width: 150, height: 5)
                            .overlay(alignment: .leading) { Capsule().fill(violet).frame(width: 62, height: 5) }
                        Text("4:12").font(.system(size: 12).monospacedDigit()).opacity(0.5)
                    }
                    Label("Download", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(violet, in: .capsule)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(.white.opacity(0.05))
                .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(panel)
        }
        .frame(width: 1240, height: 640)
        .clipShape(.rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 50, y: 26)
    }
}

struct Cover: View {
    let icon: NSImage
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 30) {
                Image(nsImage: icon).resizable().frame(width: 168, height: 168)
                    .shadow(color: .black.opacity(0.35), radius: 22, y: 12)
                VStack(alignment: .leading, spacing: 6) {
                    Text("SOULSEEK").font(.system(size: 22, weight: .bold)).tracking(7).foregroundStyle(lavender)
                    Text("Arpeggio").font(.system(size: 86, weight: .bold, design: .rounded))
                    Text("A native Soulseek client for macOS. Search, preview, download and share.")
                        .font(.system(size: 24, weight: .medium)).opacity(0.72)
                }
            }
            .padding(.top, 66)
            HStack(spacing: 12) {
                Pill(symbol: "play.circle", text: "Stream before you download")
                Pill(symbol: "menubar.arrow.up.rectangle", text: "Lives in the menu bar")
                Pill(symbol: "externaldrive.badge.wifi", text: "Easy sharing")
                Pill(symbol: "chart.bar.xaxis", text: "Statistics")
                Pill(symbol: "arrow.triangle.2.circlepath", text: "Auto-updates")
            }
            .padding(.top, 34)
            Spacer(minLength: 0)
            AppWindow().padding(.bottom, 62)
        }
        .foregroundStyle(.white)
        .frame(width: 1440, height: 1080)
        .background {
            ZStack {
                LinearGradient(colors: [Color(red: 0.19, green: 0.14, blue: 0.42), Color(red: 0.06, green: 0.05, blue: 0.14)],
                               startPoint: .top, endPoint: .bottom)
                Circle().fill(violet.opacity(0.5)).frame(width: 900).blur(radius: 190).offset(x: -420, y: -380)
                Circle().fill(Color(red: 0.95, green: 0.45, blue: 0.6).opacity(0.18)).frame(width: 760).blur(radius: 200).offset(x: 520, y: 420)
                Circle().fill(Color(red: 0.35, green: 0.55, blue: 1).opacity(0.14)).frame(width: 700).blur(radius: 200).offset(x: 560, y: -360)
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
