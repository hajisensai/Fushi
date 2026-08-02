package mextensionserver.ui

import mextensionserver.controller.MExtensionServerController
import java.awt.BorderLayout
import java.awt.Color
import java.awt.Dimension
import java.awt.FlowLayout
import java.awt.Font
import java.awt.GridBagConstraints
import java.awt.GridBagLayout
import java.awt.Image
import java.awt.Insets
import java.awt.Taskbar
import java.awt.Toolkit
import java.awt.datatransfer.StringSelection
import java.awt.event.WindowAdapter
import java.awt.event.WindowEvent
import java.net.InetAddress
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import javax.imageio.ImageIO
import javax.swing.BorderFactory
import javax.swing.JButton
import javax.swing.JFrame
import javax.swing.JLabel
import javax.swing.JPanel
import javax.swing.JScrollPane
import javax.swing.JSpinner
import javax.swing.JTextArea
import javax.swing.SpinnerNumberModel
import javax.swing.SwingConstants
import javax.swing.SwingUtilities
import javax.swing.UIManager
import javax.swing.border.EmptyBorder

class ServerWindow {
    private val controller = MExtensionServerController()
    private val frame = JFrame("MExtension Server")

    private val statusDot = JLabel("●", SwingConstants.CENTER)
    private val statusText = JLabel("Stopped")
    private val ipValue = JLabel("—")
    private val portSpinner = JSpinner(SpinnerNumberModel(0, 0, 65535, 1))
    private val portRunning = JLabel("—")

    private val startBtn = JButton("Start")
    private val stopBtn = JButton("Stop")
    private val copyBtn = JButton("Copy URL")

    private val logArea = JTextArea(9, 52)
    private val timeFmt: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm:ss")

    init {
        applyAppIcon()
        setupUI()
    }

    private fun applyAppIcon() {
        val img: Image =
            runCatching {
                ImageIO.read(ServerWindow::class.java.getResourceAsStream("/icon-black.png"))
            }.getOrNull() ?: return

        // Dock icon (macOS)
        runCatching {
            if (Taskbar.isTaskbarSupported()) {
                val tb = Taskbar.getTaskbar()
                if (tb.isSupported(Taskbar.Feature.ICON_IMAGE)) {
                    tb.iconImage = img
                }
            }
        }

        // Window title-bar icon (all platforms)
        frame.iconImage = img
        frame.iconImages = listOf(img)
    }

    private fun setupUI() {
        try {
            UIManager.setLookAndFeel(UIManager.getSystemLookAndFeelClassName())
        } catch (_: Exception) {
        }

        frame.defaultCloseOperation = JFrame.DO_NOTHING_ON_CLOSE
        frame.addWindowListener(
            object : WindowAdapter() {
                override fun windowClosing(e: WindowEvent) {
                    if (controller.isRunning()) {
                        stopBtn.isEnabled = false
                        controller.stop()
                    }
                    System.exit(0)
                }
            },
        )
        frame.setSize(500, 430)
        frame.setLocationRelativeTo(null)
        frame.isResizable = false

        val root = JPanel(BorderLayout(10, 10))
        root.border = EmptyBorder(14, 14, 14, 14)

        // ── Status card ──────────────────────────────────────────────────────
        val card = JPanel(GridBagLayout())
        card.border =
            BorderFactory.createCompoundBorder(
                BorderFactory.createLineBorder(Color(210, 210, 210), 1, true),
                EmptyBorder(10, 14, 10, 14),
            )
        val gbc = GridBagConstraints().apply { insets = Insets(4, 6, 4, 6) }

        // Row 0 – state
        statusDot.font = Font("SansSerif", Font.PLAIN, 22)
        statusDot.foreground = Color(190, 40, 40)
        statusText.font = Font("SansSerif", Font.BOLD, 13)

        gbc.gridx = 0
        gbc.gridy = 0
        gbc.anchor = GridBagConstraints.WEST
        gbc.weightx = 0.0
        gbc.fill = GridBagConstraints.NONE
        card.add(statusDot, gbc)
        gbc.gridx = 1
        gbc.weightx = 1.0
        gbc.fill = GridBagConstraints.HORIZONTAL
        card.add(statusText, gbc)

        // Row 1 – IP
        val ipLbl = lbl("IP Address:")
        gbc.gridx = 0
        gbc.gridy = 1
        gbc.weightx = 0.0
        gbc.fill = GridBagConstraints.NONE
        card.add(ipLbl, gbc)
        ipValue.font = Font("Monospaced", Font.BOLD, 13)
        gbc.gridx = 1
        gbc.weightx = 1.0
        gbc.fill = GridBagConstraints.HORIZONTAL
        card.add(ipValue, gbc)

        // Row 2 – Port (input before start, read-only after)
        gbc.gridx = 0
        gbc.gridy = 2
        gbc.weightx = 0.0
        gbc.fill = GridBagConstraints.NONE
        card.add(lbl("Port:"), gbc)

        portSpinner.preferredSize = Dimension(90, 26)
        portRunning.font = Font("Monospaced", Font.BOLD, 13)
        portRunning.isVisible = false

        val portRow = JPanel(FlowLayout(FlowLayout.LEFT, 0, 0))
        portRow.isOpaque = false
        portRow.add(portSpinner)
        portRow.add(portRunning)
        val portHint = lbl("  (0 = auto-assign)")
        portHint.font = Font("SansSerif", Font.ITALIC, 11)
        portRow.add(portHint)

        gbc.gridx = 1
        gbc.weightx = 1.0
        gbc.fill = GridBagConstraints.HORIZONTAL
        card.add(portRow, gbc)

        // ── Buttons ──────────────────────────────────────────────────────────
        startBtn.preferredSize = Dimension(100, 34)
        stopBtn.preferredSize = Dimension(100, 34)
        copyBtn.preferredSize = Dimension(110, 34)
        stopBtn.isEnabled = false
        copyBtn.isEnabled = false

        val btnRow = JPanel(FlowLayout(FlowLayout.CENTER, 10, 0))
        btnRow.isOpaque = false
        btnRow.add(startBtn)
        btnRow.add(stopBtn)
        btnRow.add(copyBtn)

        // ── Log area ─────────────────────────────────────────────────────────
        logArea.isEditable = false
        logArea.font = Font("Monospaced", Font.PLAIN, 11)
        val logScroll = JScrollPane(logArea)
        logScroll.border = BorderFactory.createTitledBorder("Log")

        // ── Layout compose ───────────────────────────────────────────────────
        val top = JPanel(BorderLayout(0, 8))
        top.isOpaque = false
        top.add(card, BorderLayout.CENTER)
        top.add(btnRow, BorderLayout.SOUTH)

        root.add(top, BorderLayout.NORTH)
        root.add(logScroll, BorderLayout.CENTER)
        frame.contentPane = root

        // ── Listeners ────────────────────────────────────────────────────────
        startBtn.addActionListener { onStart() }
        stopBtn.addActionListener { onStop() }
        copyBtn.addActionListener { onCopyUrl() }

        log("Ready — click Start to launch the server.")
    }

    private fun onStart() {
        startBtn.isEnabled = false
        portSpinner.isEnabled = false
        log("Starting server…")
        Thread {
            try {
                val requestedPort = portSpinner.value as Int
                controller.start(requestedPort)
                val port = controller.getPort()
                val ip =
                    runCatching { InetAddress.getLocalHost().hostAddress }
                        .getOrDefault("127.0.0.1")
                SwingUtilities.invokeLater {
                    statusDot.foreground = Color(30, 160, 30)
                    statusText.text = "Running"
                    ipValue.text = ip
                    portSpinner.isVisible = false
                    portRunning.text = port.toString()
                    portRunning.isVisible = true
                    stopBtn.isEnabled = true
                    copyBtn.isEnabled = true
                    log("Server started → http://$ip:$port")
                }
            } catch (e: Exception) {
                SwingUtilities.invokeLater {
                    portSpinner.isEnabled = true
                    startBtn.isEnabled = true
                    log("Error: ${e.message}")
                }
            }
        }.start()
    }

    private fun onStop() {
        stopBtn.isEnabled = false
        copyBtn.isEnabled = false
        log("Stopping server…")
        Thread {
            controller.stop()
            SwingUtilities.invokeLater {
                statusDot.foreground = Color(190, 40, 40)
                statusText.text = "Stopped"
                ipValue.text = "—"
                portRunning.isVisible = false
                portSpinner.isVisible = true
                portSpinner.isEnabled = true
                startBtn.isEnabled = true
                log("Server stopped.")
            }
        }.start()
    }

    private fun onCopyUrl() {
        val url = "http://${ipValue.text}:${portRunning.text}"
        Toolkit.getDefaultToolkit().systemClipboard.setContents(StringSelection(url), null)
        log("Copied to clipboard: $url")
    }

    private fun log(msg: String) {
        val t = LocalTime.now().format(timeFmt)
        logArea.append("[$t] $msg\n")
        logArea.caretPosition = logArea.document.length
    }

    private fun lbl(text: String) =
        JLabel(text).also {
            it.foreground = Color.GRAY
            it.font = Font("SansSerif", Font.PLAIN, 12)
        }

    fun show() {
        frame.isVisible = true
    }
}
