/// 已验证的应用字号快捷键。具体虚拟键码与事件投递归系统层，不在账本里操作应用。
public enum ZoomShortcut: Equatable, Sendable {
    case commandEqual
    case commandShiftEqual
    case commandMinus
}
