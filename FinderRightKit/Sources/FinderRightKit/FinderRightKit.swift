/// FinderRightKit — macOS Finder 右键增强应用核心业务逻辑层
///
/// 提供跨进程 IPC 桥接与共享配置管理等基础服务。

@_exported import struct Foundation.URL
@_exported import class Foundation.UserDefaults

// 主要类型：
// IPCBridge / IPCRequest / IPCResponse / AnyJSON — from Services/XPCEndpointBridge.swift
// SharedConfig / ActionShortcut / FileTemplate    — from Services/SharedConfig.swift
