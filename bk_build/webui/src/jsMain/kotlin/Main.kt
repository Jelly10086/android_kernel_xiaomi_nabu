@file:OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)

import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.PagerState
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalFontFamilyResolver
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.platform.Font as PlatformFont
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.ComposeViewport
import kotlinx.browser.window
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.await
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import org.bkkernel.control.generated.resources.Res
import org.bkkernel.control.generated.resources.save_log
import org.jetbrains.compose.resources.painterResource
import org.khronos.webgl.Int8Array
import org.w3c.fetch.RequestInit
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.CardDefaults
import top.yukonga.miuix.kmp.basic.DropdownEntry
import top.yukonga.miuix.kmp.basic.DropdownItem
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.MiuixScrollBehavior
import top.yukonga.miuix.kmp.basic.NavigationBar
import top.yukonga.miuix.kmp.basic.NavigationBarItem
import top.yukonga.miuix.kmp.basic.NavigationRail
import top.yukonga.miuix.kmp.basic.NavigationRailItem
import top.yukonga.miuix.kmp.basic.Scaffold
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TopAppBar
import top.yukonga.miuix.kmp.basic.rememberNavigationRailState
import top.yukonga.miuix.kmp.menu.OverlayIconDropdownMenu
import top.yukonga.miuix.kmp.preference.OverlayDropdownPreference
import top.yukonga.miuix.kmp.preference.SwitchPreference
import top.yukonga.miuix.kmp.theme.ColorSchemeMode
import top.yukonga.miuix.kmp.theme.MiuixTheme
import top.yukonga.miuix.kmp.theme.ThemeColorSpec
import top.yukonga.miuix.kmp.theme.ThemeController
import top.yukonga.miuix.kmp.theme.ThemePaletteStyle
import kotlin.js.Promise
import kotlin.js.json
import kotlin.js.unsafeCast
import kotlin.math.abs

private const val BKCTL = "/data/adb/modules/bk-control/bkctl"
private const val FONT_URL = "composeResources/org.bkkernel.control.generated.resources/font/bk_cjk.ttf"

private external fun bkExec(command: String): Promise<dynamic>
private external fun bkExportLog(command: String): Promise<dynamic>
private external fun bkReducedMotion(): Boolean
private external fun bkThemeSeed(): Int

private data class ControlState(
    val systemVersion: String = "读取中",
    val androidVersion: String = "读取中",
    val kernel: String = "读取中",
    val mode: String = "auto",
    val runtimeMode: String = "读取中",
    val keyboardEnabled: Boolean = false,
    val audioBoost: Boolean = true,
    val protectedWriteback: Boolean = true,
    val widgetBoost: Boolean = true,
    val touchFirmware: String = "modern",
    val swappiness: String = "180",
)

private data class ExecResult(val errno: Int, val stdout: String, val stderr: String)

private suspend fun runBkctl(arguments: String): ExecResult {
    val raw = bkExec("$BKCTL $arguments").await()
    return ExecResult(
        errno = raw.errno.unsafeCast<Int>(),
        stdout = raw.stdout.unsafeCast<String>(),
        stderr = raw.stderr.unsafeCast<String>(),
    )
}

private fun parseState(text: String): ControlState {
    val values = text.lineSequence()
        .mapNotNull { line ->
            val separator = line.indexOf('=')
            if (separator <= 0) null else line.substring(0, separator) to line.substring(separator + 1)
        }
        .toMap()
    return ControlState(
        systemVersion = values["system_version"] ?: "未知",
        androidVersion = values["android_version"] ?: "未知",
        kernel = values["kernel"] ?: "未知",
        mode = values["mode"] ?: "auto",
        runtimeMode = values["runtime_mode"] ?: "unknown",
        keyboardEnabled = values["keyboard_enabled"] == "1",
        audioBoost = values["audio_boost"] != "0",
        protectedWriteback = values["protected_writeback"] != "0",
        widgetBoost = values["widget_boost"] != "0",
        touchFirmware = values["touch_firmware"] ?: "modern",
        swappiness = values["swappiness"] ?: "180",
    )
}

private fun runtimeLabel(mode: String): String = when (mode) {
    "active" -> "高性能运行中"
    "warming" -> "等待负载"
    "cooling" -> "温控冷却"
    "disabled" -> "策略已停用"
    "inactive" -> "均衡运行中"
    else -> "状态读取中"
}

private fun parseThemeSeed(text: String): Color? {
    val hex = text.trim().removePrefix("#")
    val argb = when (hex.length) {
        6 -> hex.toLongOrNull(16)?.or(0xFF000000)
        8 -> hex.toLongOrNull(16)
        else -> null
    }
    return argb?.let { Color(it.toInt()) }
}

fun main() {
    ComposeViewport(viewportContainerId = "composeApp") {
        FontBootstrap()
    }
}

@Composable
private fun FontBootstrap() {
    val resolver = LocalFontFamilyResolver.current
    var ready by remember { mutableStateOf(false) }
    var themeSeed by remember { mutableStateOf(Color(0xFF6750A4)) }

    LaunchedEffect(resolver) {
        val managerSeed = bkThemeSeed()
        themeSeed = if (managerSeed != 0) {
            Color(managerSeed)
        } else {
            runCatching { runBkctl("theme-seed") }
                .getOrNull()
                ?.takeIf { it.errno == 0 }
                ?.let { parseThemeSeed(it.stdout) }
                ?: themeSeed
        }
        runCatching {
            val response = window.fetch(FONT_URL, json().unsafeCast<RequestInit>()).await()
            if (!response.ok) error("font HTTP ${response.status}")
            val bytes = Int8Array(response.arrayBuffer().await()).unsafeCast<ByteArray>()
            val font = PlatformFont(
                identity = FONT_URL,
                getData = { bytes },
                weight = FontWeight.Normal,
                style = FontStyle.Normal,
            )
            resolver.preload(FontFamily(font))
        }
        ready = true
    }

    if (ready) {
        val controller = remember(themeSeed) {
            ThemeController(
                colorSchemeMode = ColorSchemeMode.MonetSystem,
                keyColor = themeSeed,
                colorSpec = ThemeColorSpec.Spec2025,
                paletteStyle = ThemePaletteStyle.TonalSpot,
                isDark = null,
            )
        }
        MiuixTheme(controller = controller) {
            ControlScreen()
        }
    }
}

@Composable
private fun ControlScreen() {
    var state by remember { mutableStateOf(ControlState()) }
    var message by remember { mutableStateOf("正在读取内核状态") }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val pagerState = rememberPagerState(pageCount = { 2 })
    val mainPagerState = rememberMainPagerState(pagerState, bkReducedMotion())

    LaunchedEffect(pagerState.currentPage) {
        mainPagerState.syncPage()
    }

    fun refresh() {
        scope.launch {
            busy = true
            runCatching { runBkctl("get-all") }
                .onSuccess {
                    if (it.errno == 0) {
                        state = parseState(it.stdout)
                        message = "配置已同步"
                    } else {
                        message = it.stderr.ifBlank { "读取失败：${it.errno}" }
                    }
                }
                .onFailure { message = it.message ?: "KernelSU 接口不可用" }
            busy = false
        }
    }

    fun setValue(key: String, value: String) {
        scope.launch {
            busy = true
            runCatching { runBkctl("set $key $value") }
                .onSuccess {
                    message = if (it.errno == 0) "设置已应用" else it.stderr.ifBlank { "设置失败：${it.errno}" }
                }
                .onFailure { message = it.message ?: "设置失败" }
            val current = runCatching { runBkctl("get-all") }.getOrNull()
            if (current?.errno == 0) state = parseState(current.stdout)
            busy = false
        }
    }

    fun saveLogs() {
        scope.launch {
            busy = true
            runCatching {
                val raw = bkExportLog("$BKCTL collect-log").await()
                ExecResult(
                    errno = raw.errno.unsafeCast<Int>(),
                    stdout = raw.stdout.unsafeCast<String>(),
                    stderr = raw.stderr.unsafeCast<String>(),
                )
            }.onSuccess {
                message = when (it.errno) {
                    0 -> it.stdout.trim()
                    130 -> "已取消日志导出"
                    else -> it.stderr.ifBlank { "日志保存失败：${it.errno}" }
                }
            }.onFailure { message = it.message ?: "日志保存失败" }
            busy = false
        }
    }

    LaunchedEffect(Unit) { refresh() }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val useNavigationRail = maxWidth >= 840.dp ||
            (maxWidth >= 600.dp && maxHeight.value / maxWidth.value < 1.2f)
        val pagerContent = @Composable { bottomPadding: Dp ->
            HorizontalPager(
                modifier = Modifier.fillMaxSize(),
                state = mainPagerState.pagerState,
                beyondViewportPageCount = 1,
            ) { page ->
                when (page) {
                    0 -> HomePager(
                        state = state,
                        message = message,
                        busy = busy,
                        bottomPadding = bottomPadding,
                        onRefresh = ::refresh,
                        onSaveLogs = ::saveLogs,
                    )

                    1 -> PolicyPager(
                        state = state,
                        message = message,
                        busy = busy,
                        bottomPadding = bottomPadding,
                        onSaveLogs = ::saveLogs,
                        onSetValue = ::setValue,
                    )
                }
            }
        }

        if (useNavigationRail) {
            Scaffold {
                Row(Modifier.fillMaxSize()) {
                    ControlNavigationRail(mainPagerState)
                    Box(Modifier.weight(1f)) {
                        pagerContent(0.dp)
                    }
                }
            }
        } else {
            Scaffold(
                bottomBar = { ControlBottomBar(mainPagerState) },
            ) { innerPadding ->
                pagerContent(innerPadding.calculateBottomPadding())
            }
        }
    }
}

private class MainPagerState(
    val pagerState: PagerState,
    private val coroutineScope: CoroutineScope,
    private val reducedMotion: Boolean,
) {
    var selectedPage by mutableIntStateOf(pagerState.currentPage)
        private set

    private var isNavigating by mutableStateOf(false)
    private var navJob: Job? = null

    fun animateToPage(targetIndex: Int) {
        if (targetIndex == selectedPage) return
        navJob?.cancel()
        selectedPage = targetIndex
        isNavigating = true
        val distance = abs(targetIndex - pagerState.currentPage).coerceAtLeast(2)
        val duration = 100 * distance + 100
        val layoutInfo = pagerState.layoutInfo
        val pageSize = layoutInfo.pageSize + layoutInfo.pageSpacing
        val pages = targetIndex - pagerState.currentPage - pagerState.currentPageOffsetFraction

        navJob = coroutineScope.launch {
            val myJob = coroutineContext.job
            try {
                if (reducedMotion) {
                    pagerState.scrollToPage(targetIndex)
                } else {
                    pagerState.animateScrollBy(
                        value = pages * pageSize,
                        animationSpec = tween(easing = EaseInOut, durationMillis = duration),
                    )
                }
            } finally {
                if (navJob == myJob) {
                    isNavigating = false
                    if (pagerState.currentPage != targetIndex) {
                        selectedPage = pagerState.currentPage
                    }
                }
            }
        }
    }

    fun syncPage() {
        if (!isNavigating && selectedPage != pagerState.currentPage) {
            selectedPage = pagerState.currentPage
        }
    }
}

@Composable
private fun rememberMainPagerState(
    pagerState: PagerState,
    reducedMotion: Boolean,
    coroutineScope: CoroutineScope = rememberCoroutineScope(),
): MainPagerState = remember(pagerState, coroutineScope, reducedMotion) {
    MainPagerState(pagerState, coroutineScope, reducedMotion)
}

private data class NavigationDestination(
    val label: String,
    val icon: ImageVector,
)

private val navigationDestinations by lazy {
    listOf(
        NavigationDestination("主页", HomeIcon),
        NavigationDestination("策略", PolicyIcon),
    )
}

@Composable
private fun ControlBottomBar(mainState: MainPagerState) {
    NavigationBar(
        color = MiuixTheme.colorScheme.surface,
    ) {
        navigationDestinations.forEachIndexed { index, destination ->
            NavigationBarItem(
                modifier = Modifier.weight(1f),
                icon = destination.icon,
                label = destination.label,
                selected = mainState.selectedPage == index,
                onClick = { mainState.animateToPage(index) },
            )
        }
    }
}

@Composable
private fun ControlNavigationRail(mainState: MainPagerState) {
    NavigationRail(
        state = rememberNavigationRailState(),
        color = MiuixTheme.colorScheme.surface,
        expandContentDescription = "展开导航",
        collapseContentDescription = "收起导航",
    ) {
        navigationDestinations.forEachIndexed { index, destination ->
            NavigationRailItem(
                selected = mainState.selectedPage == index,
                onClick = { mainState.animateToPage(index) },
                icon = destination.icon,
                label = destination.label,
            )
        }
    }
}

@Composable
private fun HomePager(
    state: ControlState,
    message: String,
    busy: Boolean,
    bottomPadding: Dp,
    onRefresh: () -> Unit,
    onSaveLogs: () -> Unit,
) {
    val scrollBehavior = MiuixScrollBehavior()
    Scaffold(
        topBar = {
            TopAppBar(
                title = "bkk-control",
                scrollBehavior = scrollBehavior,
                actions = { LogAction(enabled = !busy, onClick = onSaveLogs) },
            )
        },
        popupHost = {},
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxHeight()
                .nestedScroll(scrollBehavior.nestedScrollConnection)
                .padding(horizontal = 12.dp),
            contentPadding = PaddingValues(
                top = innerPadding.calculateTopPadding() + 12.dp,
                bottom = innerPadding.calculateBottomPadding() + bottomPadding + 12.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                StatusCard(
                    state = state,
                    message = message,
                    busy = busy,
                    onRefresh = onRefresh,
                )
            }
            item {
                InfoCard(state)
            }
        }
    }
}

@Composable
private fun StatusCard(
    state: ControlState,
    message: String,
    busy: Boolean,
    onRefresh: () -> Unit,
) {
    val running = state.kernel != "读取中" && state.kernel != "未知" && state.runtimeMode != "unknown"
    Card(
        modifier = Modifier.fillMaxWidth().height(IntrinsicSize.Min),
        colors = CardDefaults.defaultColors(
            color = if (running) MiuixTheme.colorScheme.secondaryContainer else MiuixTheme.colorScheme.errorContainer,
        ),
        onClick = if (busy) null else onRefresh,
    ) {
        Box(Modifier.fillMaxSize()) {
            Box(
                modifier = Modifier.fillMaxSize().offset(27.dp, 31.dp),
                contentAlignment = Alignment.BottomEnd,
            ) {
                Icon(
                    imageVector = if (running) KsuCheckCircleIcon else KsuErrorOutlineIcon,
                    contentDescription = null,
                    modifier = Modifier.size(110.dp),
                    tint = if (running) {
                        MiuixTheme.colorScheme.primary.copy(alpha = 0.8f)
                    } else {
                        MiuixTheme.colorScheme.error.copy(alpha = 0.8f)
                    },
                )
            }
            Column(Modifier.padding(horizontal = 16.dp, vertical = 14.dp)) {
                Text(
                    text = if (running) "内核运行中" else "内核状态异常",
                    fontSize = 22.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    text = if (running) runtimeLabel(state.runtimeMode) else message,
                    modifier = Modifier.padding(top = 2.dp),
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Medium,
                )
                Spacer(Modifier.height(58.dp))
                Text(
                    text = state.kernel,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                )
            }
        }
    }
}

@Composable
private fun InfoCard(state: ControlState) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().padding(16.dp)) {
            InfoText("系统版本", state.systemVersion)
            InfoText("Android 版本", state.androidVersion)
            InfoText("内核版本", state.kernel)
            InfoText("运行状态", runtimeLabel(state.runtimeMode))
            InfoText("ZRAM swappiness", state.swappiness, bottomPadding = 0.dp)
        }
    }
}

@Composable
private fun InfoText(label: String, value: String, bottomPadding: Dp = 22.dp) {
    Text(
        text = label,
        fontSize = MiuixTheme.textStyles.headline1.fontSize,
        fontWeight = FontWeight.Medium,
        color = MiuixTheme.colorScheme.onSurface,
    )
    Text(
        text = value,
        modifier = Modifier.padding(top = 2.dp, bottom = bottomPadding),
        fontSize = MiuixTheme.textStyles.body2.fontSize,
        color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
    )
}

@Composable
private fun PolicyPager(
    state: ControlState,
    message: String,
    busy: Boolean,
    bottomPadding: Dp,
    onSaveLogs: () -> Unit,
    onSetValue: (String, String) -> Unit,
) {
    val scrollBehavior = MiuixScrollBehavior()
    val modeValues = listOf("auto", "force", "disabled")
    val modeLabels = listOf("自动", "强制", "停用")
    val swappinessValues = listOf("160", "180")
    val swappinessLabels = listOf("均衡 160", "积极 180")
    val firmwareValues = listOf("modern", "miui125")
    val firmwareLabels = listOf("新版", "MIUI 12.5")

    Scaffold(
        topBar = {
            TopAppBar(
                title = "bk-kernel运行策略",
                scrollBehavior = scrollBehavior,
                actions = { LogAction(enabled = !busy, onClick = onSaveLogs) },
            )
        },
        popupHost = {},
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxHeight()
                .nestedScroll(scrollBehavior.nestedScrollConnection)
                .padding(horizontal = 12.dp),
            contentPadding = PaddingValues(
                top = innerPadding.calculateTopPadding() + 12.dp,
                bottom = innerPadding.calculateBottomPadding() + bottomPadding + 12.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Card(Modifier.fillMaxWidth()) {
                    OverlayDropdownPreference(
                        title = "运行模式",
                        summary = "按负载和温度切换性能策略",
                        items = modeLabels,
                        selectedIndex = modeValues.indexOf(state.mode).coerceAtLeast(0),
                        enabled = !busy,
                        onSelectedIndexChange = { onSetValue("mode", modeValues[it]) },
                    )
                    SwitchPreference(
                        title = "小组件场景提升",
                        summary = "桌面高负载时提升渲染线程",
                        checked = state.widgetBoost,
                        enabled = !busy,
                        onCheckedChange = { onSetValue("widget_boost", if (it) "1" else "0") },
                    )
                    SwitchPreference(
                        title = "音频低延迟",
                        summary = "优先调度音频线程",
                        checked = state.audioBoost,
                        enabled = !busy,
                        onCheckedChange = { onSetValue("audio_boost", if (it) "1" else "0") },
                    )
                }
            }
            item {
                Card(Modifier.fillMaxWidth()) {
                    SwitchPreference(
                        title = "受保护 ZRAM 回写",
                        summary = "仅在熄屏、低内存和低负载时回写",
                        checked = state.protectedWriteback,
                        enabled = !busy,
                        onCheckedChange = { onSetValue("protected_writeback", if (it) "1" else "0") },
                    )
                    OverlayDropdownPreference(
                        title = "ZRAM swappiness",
                        summary = "控制匿名页换出倾向",
                        items = swappinessLabels,
                        selectedIndex = swappinessValues.indexOf(state.swappiness).coerceAtLeast(0),
                        enabled = !busy,
                        onSelectedIndexChange = { onSetValue("swappiness", swappinessValues[it]) },
                    )
                }
            }
            item {
                Card(Modifier.fillMaxWidth()) {
                    OverlayDropdownPreference(
                        title = "触控固件",
                        summary = "熄屏再亮屏后切换",
                        items = firmwareLabels,
                        selectedIndex = firmwareValues.indexOf(state.touchFirmware).coerceAtLeast(0),
                        enabled = !busy,
                        onSelectedIndexChange = { onSetValue("touch_firmware", firmwareValues[it]) },
                    )
                }
            }
            item {
                Card(Modifier.fillMaxWidth()) {
                    SwitchPreference(
                        title = "磁吸键盘接口",
                        summary = "控制键盘供电和热插拔检测",
                        checked = state.keyboardEnabled,
                        enabled = !busy,
                        onCheckedChange = { onSetValue("keyboard_enabled", if (it) "1" else "0") },
                    )
                }
            }
            item {
                Text(
                    text = message,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                    fontSize = 13.sp,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

@Composable
private fun LogAction(enabled: Boolean, onClick: () -> Unit) {
    val entry = DropdownEntry(
        items = listOf(
            DropdownItem(
                text = "保存完整日志",
                summary = "运行日志与内核日志",
                onClick = onClick,
            ),
        ),
    )
    OverlayIconDropdownMenu(entry = entry, enabled = enabled) {
        Image(
            painter = painterResource(Res.drawable.save_log),
            contentDescription = "日志",
            modifier = Modifier.size(24.dp),
            colorFilter = ColorFilter.tint(
                if (enabled) MiuixTheme.colorScheme.onSurface else MiuixTheme.colorScheme.disabledOnSurface,
            ),
        )
    }
}

private fun vectorIcon(pathData: String): ImageVector = ImageVector.Builder(
    defaultWidth = 24.dp,
    defaultHeight = 24.dp,
    viewportWidth = 24f,
    viewportHeight = 24f,
).apply {
    addPath(
        pathData = PathParser().parsePathString(pathData).toNodes(),
        fill = SolidColor(Color.Black),
    )
}.build()

private val HomeIcon = vectorIcon(
    "M6 19h3v-6h6v6h3v-9l-6-4.5L6 10v9Zm-2 2V9l8-6 8 6v12h-7v-6h-2v6H4Z",
)

private val PolicyIcon = vectorIcon(
    "M11 19.425v-6.85L5 9.1v6.85l6 3.475Zm2 0 6-3.475V9.1l-6 3.475v6.85Zm-1-8.575 5.925-3.425L12 4 6.075 7.425 12 10.85ZM4 17.7q-.475-.275-.738-.725T3 15.975v-7.95q0-.55.263-1T4 6.3l7-4.025Q11.475 2 12 2t1 .275L20 6.3q.475.275.738.725t.262 1v7.95q0 .55-.262 1T20 17.7l-7 4.025Q12.525 22 12 22t-1-.275L4 17.7Z",
)

private val KsuCheckCircleIcon = vectorIcon(
    "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2Zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8Zm4.59-12.42L10 14.17l-3.59-3.58L5 12l5 5 8-8-1.41-1.42Z",
)

private val KsuErrorOutlineIcon = vectorIcon(
    "M11 15h2v2h-2v-2Zm0-8h2v6h-2V7Zm.99-5C6.47 2 2 6.48 2 12s4.47 10 9.99 10S22 17.52 22 12 17.51 2 11.99 2ZM12 20a8 8 0 1 1 0-16 8 8 0 0 1 0 16Z",
)
