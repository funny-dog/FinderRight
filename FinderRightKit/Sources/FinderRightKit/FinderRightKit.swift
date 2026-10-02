/// FinderRightKit — macOS Finder 右键增强应用核心业务逻辑层
///
/// 提供跨进程 IPC 桥接与共享配置管理等基础服务。

@_exported import struct Foundation.URL
@_exported import class Foundation.UserDefaults

// 主要类型：
// IPCBridge / IPCRequest / IPCResponse / AnyJSON — from Services/XPCEndpointBridge.swift
// SharedConfig / ActionShortcut / FileTemplate    — from Services/SharedConfig.swift
// ProcessRunner（子进程执行，先读 stderr 防死锁）  — from Services/ProcessRunner.swift
// SafeFileName（新建文件名校验，防路径穿越）       — from SafeFileName.swift
// UpdateIntegrity（更新包校验和解析）              — from UpdateIntegrity.swift
// PathAccessPolicy（白名单 + FDA 专属数据拦截）     — from PathAccessPolicy.swift
// ServiceInvocationPolicy（Services 调用方校验）   — from ServiceInvocationPolicy.swift
// CutQueueCache（剪切队列只读缓存，角标热路径）     — from Services/CutQueueCache.swift
// ScratchDirectoryRegistry（压缩临时目录登记与清扫）— from Services/ScratchDirectoryRegistry.swift
// ZipCompressor（压缩：退出码判定 + 原子改名）     — from Services/ZipCompressor.swift
// XZDecompressor（.xz 进程内解压）                 — from Services/XZDecompressor.swift
// BackgroundJobs（在途后台任务，退出前等待）        — from Services/BackgroundJobs.swift
