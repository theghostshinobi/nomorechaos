# NoMoreChaos

![NoMoreChaos HUD Preview](Assets/nomorechaos_hud_preview.png)

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

To function correctly and efficiently, NoMoreChaos requires two standard macOS system permissions. The app features an initial **Setup Wizard** that guides you step-by-step through the configuration:

### 1. Screen Recording
* **Why it is needed**: Allows NoMoreChaos to capture visual thumbnails (live screenshots) of windows to display real-time previews inside the HUD and the Visual Map.
* **Security**: Images are processed entirely locally and are never saved to disk or transmitted over the network.

### 2. Accessibility
* **Why it is needed**: This is the standard permission used by all window managers (such as Rectangle or Magnet). It allows the application to physically move, resize, minimize, and bring specific windows to the front when you perform a jump.

---

## 🛠️ Getting Started

1. Download the application and run **NoMoreChaos.app**.
2. Complete the initial **Setup Wizard** to enable Screen Recording and Accessibility permissions.
3. Create your first Project.
4. Press `+ Add Window` to connect windows currently open on your Mac.
5. Use the arrow keys and press **Enter** on the HUD, or click nodes on the **Visual Map** to jump instantly between projects!
