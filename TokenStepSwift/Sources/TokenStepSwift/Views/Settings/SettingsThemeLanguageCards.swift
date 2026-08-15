import SwiftUI

struct SettingsThemeCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(title: L("9 套主题"), symbol: "paintpalette.fill", height: 112) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    ForEach(TokenStepTheme.allCases) { theme in
                        ThemeSwatchButton(
                            theme: theme,
                            selected: appState.settings.theme == theme
                        ) {
                            appState.setTheme(theme)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }
}

struct SettingsLanguageCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(title: L("语言"), symbol: "globe.asia.australia.fill", height: 150) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("选择 TokenFleet 的显示语言"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(TokenStepLanguage.allCases) { language in
                        LanguageOptionButton(
                            language: language,
                            selected: appState.settings.language == language
                        ) {
                            appState.setLanguage(language)
                        }
                    }
                }

            }
        }
    }
}
