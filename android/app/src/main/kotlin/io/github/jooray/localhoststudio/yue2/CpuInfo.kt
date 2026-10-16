package io.github.jooray.localhoststudio.yue2

import java.io.File

/** Core topology from cpufreq: "big" = every core faster than the slowest cluster. */
object CpuInfo {
    data class Core(val id: Int, val maxKhz: Long)

    val cores: List<Core> by lazy {
        val n = Runtime.getRuntime().availableProcessors().coerceAtLeast(1)
        val all = (0 until maxOf(n, 16)).mapNotNull { id ->
            val f = File("/sys/devices/system/cpu/cpu$id/cpufreq/cpuinfo_max_freq")
            if (!File("/sys/devices/system/cpu/cpu$id").exists()) return@mapNotNull null
            val khz = runCatching { f.readText().trim().toLong() }.getOrDefault(0L)
            Core(id, khz)
        }
        all.ifEmpty { (0 until n).map { Core(it, 0) } }
    }

    val bigCores: List<Int> by lazy {
        val freqs = cores.map { it.maxKhz }.filter { it > 0 }
        if (freqs.isEmpty() || freqs.distinct().size == 1) {
            cores.map { it.id }
        } else {
            val slowest = freqs.min()
            cores.filter { it.maxKhz > slowest }.map { it.id }
        }
    }

    fun describe(): String = cores.groupBy { it.maxKhz }.entries.sortedBy { it.key }
        .joinToString(", ") { (khz, cs) -> "${cs.size}× ${"%.2f".format(khz / 1e6)} GHz" }
}
