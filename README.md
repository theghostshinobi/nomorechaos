# NoMoreChaos

![NoMoreChaos HUD Preview](Assets/nomorechaos_hud_preview.png)

## 📥 [Download NoMoreChaos v1.0.0 (macOS DMG)](https://github.com/theghostshinobi/nomorechaos/releases/download/v1.0.0/NoMoreChaos.dmg)

---

**NoMoreChaos** is a premium window manager for macOS designed to eliminate visual clutter and organize your workspace logically and fluidly. It groups open windows from any application into coherent "Projects", allowing you to jump instantly between different workflows without distractions.

---

## 🚀 Key Features

### 1. Project Management & HUD Preview
Associate physical windows with specific custom projects. The HUD interface displays live thumbnails of assigned windows with the ability to remove them in one click.

![NoMoreChaos HUD Preview](Assets/nomorechaos_hud_preview.png)

### 2. Quick Window Addition
View a complete list of all open windows on your Mac, grouped by application, with the ability to add individual windows or assign all windows of an application in bulk (via the green "+ Add All" button).

![NoMoreChaos Add Open Windows](Assets/nomorechaos_hud_list.png)

### 3. Interactive Visual Map
Display a node-based tree map of all your projects and connected windows with dynamic connection lines to understand at a glance how your workspaces are structured.

![NoMoreChaos Visual Map](Assets/nomorechaos_visual_map.png)

### 4. Glowing Window Highlight
When you jump to a window, it is instantly highlighted with a high-contrast glowing white border for 1 second, providing immediate visual feedback of where you landed.

### 5. Instant Preview Load
Utilizes a super-fast, low-latency native pipeline (<10ms) to capture and render live window screenshots in both the HUD and the Visual Map.

---

## 🔒 macOS Permissions Workflow

To function correctly and efficiently, NoMoreChaos requires two standard macOS system permissions. The application includes a built-in **Setup Wizard** to guide you through the process, but you can also configure them manually:

### 1. Screen Recording (Screen & System Audio Recording)
* **Why it is needed**: Enables NoMoreChaos to capture real-time, low-latency thumbnails (live screenshots) of your active windows to display previews inside the HUD and the interactive Visual Map.
* **Security & Privacy**: Screen captures are processed strictly in volatile memory (RAM) and rendered locally. No images are saved to disk, tracked, or transmitted over any network.
* **How to enable**:
  1. Go to **System Settings > Privacy & Security > Screen & System Audio Recording** (on macOS Sequoia and later) or **Screen Recording** (on older macOS versions).
  2. Find **NoMoreChaos** in the list and toggle the switch to **ON**.
  3. If macOS prompts you to "Quit & Reopen" or do it "Later", select **Quit & Reopen** (or quit manually and restart the app) to apply the permission.

### 2. Accessibility
* **Why it is needed**: Standard window control API permission used by macOS utility apps (similar to Rectangle or Magnet). It allows NoMoreChaos to move, focus, unminimize, and bring the assigned window to the front when you trigger a "jump".
* **How to enable**:
  1. Go to **System Settings > Privacy & Security > Accessibility**.
  2. Find **NoMoreChaos** in the list and toggle the switch to **ON**.
  3. If **NoMoreChaos** is not present in the list:
     - Click the `+` button at the bottom of the list.
     - Authenticate with your Mac password/Touch ID.
     - Navigate to `/Applications` or wherever you placed the app and select **NoMoreChaos.app** to add it, then ensure the switch is toggled **ON**.

---

## 🛠️ Troubleshooting Stuck Permissions (TCC Reset)

On macOS, permissions database states can sometimes become out-of-sync or "stuck" (e.g. showing as checked in System Settings but remaining inactive in the OS). This is common when testing multiple builds or moving the app bundle.

If NoMoreChaos continues to request permissions even after you have enabled them:

1. Close the application.
2. Open terminal and reset the system permission database for NoMoreChaos:
   ```bash
   tccutil reset Accessibility com.nomorechaos.app
   tccutil reset ScreenCapture com.nomorechaos.app
   ```
3. Re-launch **NoMoreChaos.app**. The Setup Wizard will reappear, and toggle the switches back **ON** in System Settings when prompted. This forces macOS to reload the settings correctly.

---

## 🛠️ Getting Started

1. **Download**: Obtain the latest release from the download link above.
2. **Install**: Double-click the `.dmg` file and drag **NoMoreChaos** into your `/Applications` directory.
3. **Authorize**: Open the app and follow the Setup Wizard to authorize Screen Recording and Accessibility permissions.
4. **Create Projects**: Press the shortcut or click the status bar icon to show the HUD, then create your workspace projects.
5. **Assign & Switch**: Assign open windows to your projects. Press `Enter` on a window to jump instantly, or open the **Visual Map** for an interactive overview of your workspaces!
