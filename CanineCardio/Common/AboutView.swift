import SwiftUI

struct AboutView: View {
    var body: some View {
        List {
            Section {
                Text("CanineCardio is an experimental, open-source research tool for investigating whether an iPhone resting on a dog's chest can detect individual heartbeats.")
                Text("It is **not** a medical or veterinary device. It has **not** been validated for canine diagnostics and **cannot replace a veterinary ECG**. Do not use it to make decisions about an animal's health.")
                    .foregroundStyle(.red)
            }
            Section("What this version does") {
                Text("Records raw accelerometer (g, including gravity) and gyroscope (rad/s) data at a requested 100 Hz with the actual sensor timestamps, plus unprocessed microphone audio at the hardware sample rate.")
                Text("Stores each session locally and exports motion as CSV and audio as WAV, with a metadata.json describing timing, sampling statistics and device information.")
                Text("It does not estimate heart rate yet. The first goal is to establish whether the recorded signals contain usable cardiac information.")
            }
            Section("Measuring") {
                Text("Only measure a calm, resting dog that is comfortable being handled. Stop if the dog shows any discomfort.")
                Text("Use a start delay, place the phone gently on the left chest wall behind the elbow (screen up), and keep your hands off the phone while recording if possible.")
                Text("No haptics or sounds are played during recording, so they cannot contaminate the signals.")
            }
            Section("Privacy") {
                Text("No accounts, analytics or network access. Data stays on this device unless you export it.")
            }
            Section("Licence") {
                Text("MIT licence. Source code and documentation are in the project repository.")
            }
        }
        .navigationTitle("About")
    }
}
