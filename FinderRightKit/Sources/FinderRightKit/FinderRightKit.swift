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
