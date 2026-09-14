"""
风控日志处理中状态查询服务。

功能：
1. 按账号判断是否已有处理中的风控任务
2. 处理中状态带超时窗口，避免任务异常中断后遗留的僵尸记录永久阻塞账号
3. 查询失败时返回明确原因，由调用方按保守策略跳过重复处理
4. 数据库连接异常时自动重试
"""
from __future__ import annotations

import asyncio
import os
from dataclasses import dataclass

from sqlalchemy import exists, func, select, text

from common.db.session import async_session_maker
from common.models.risk_control_log import XYRiskControlLog


# 处理中状态的有效期（分钟）。
# 滑块/风控任务正常耗时为几十秒到数分钟，超过该时长仍处于 processing 的
# 记录，基本可判定为上次任务异常中断（进程被杀、请求 500、服务重启等）
# 遗留的僵尸记录。这类记录不再计入占用，使账号能够自动恢复，
# 而不是像以前那样必须人工改库才能解除阻塞。
_DEFAULT_PROCESSING_TIMEOUT_MINUTES = 10


def get_processing_timeout_minutes() -> int:
    """获取处理中状态有效期（分钟）。

    可通过环境变量 RISK_CONTROL_PROCESSING_TIMEOUT_MINUTES 覆盖，
    取值范围 1 分钟 ~ 24 小时，非法值回退为默认值。

    Returns:
        有效期分钟数。
    """
    raw = os.getenv("RISK_CONTROL_PROCESSING_TIMEOUT_MINUTES", "").strip()
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return _DEFAULT_PROCESSING_TIMEOUT_MINUTES
    return max(1, min(value, 24 * 60))


_ACCOUNT_RISK_CONTROL_LOCKS: dict[str, asyncio.Lock] = {}


def get_account_risk_control_lock(account_identifier: str) -> asyncio.Lock:
    """获取进程内账号级风控抢占锁。

    查询处理中状态和创建 processing 日志必须在同一把锁内完成，避免同一
    WebSocket 进程中的两个协程同时通过检查。

    Args:
        account_identifier: 账号业务标识。
    Returns:
        当前进程内该账号共用的异步锁。
    """
    clean_identifier = str(account_identifier or "").strip() or "__empty__"
    lock = _ACCOUNT_RISK_CONTROL_LOCKS.get(clean_identifier)
    if lock is None:
        lock = asyncio.Lock()
        _ACCOUNT_RISK_CONTROL_LOCKS[clean_identifier] = lock
    return lock


@dataclass(frozen=True, slots=True)
class ProcessingRiskControlCheckResult:
    """账号处理中风控日志检查结果。"""

    success: bool
    has_processing: bool
    message: str = ""


async def check_account_processing_risk_control_log(
    account_identifier: str,
    *,
    max_attempts: int = 3,
    retry_delay_seconds: float = 0.5,
) -> ProcessingRiskControlCheckResult:
    """检查指定账号是否已有处理中的风控日志。

    Args:
        account_identifier: 账号业务标识，对应风控日志 account_identifier。
        max_attempts: 数据库查询最大尝试次数。
        retry_delay_seconds: 相邻重试之间的等待秒数。
    Returns:
        查询成功时返回实际占用状态；查询失败时按保守策略返回占用。
    """
    clean_identifier = str(account_identifier or "").strip()
    if not clean_identifier:
        return ProcessingRiskControlCheckResult(
            False,
            True,
            "账号标识为空，无法检查处理中风控日志",
        )

    attempts = max(1, int(max_attempts))
    timeout_minutes = get_processing_timeout_minutes()
    last_error = ""
    for attempt in range(1, attempts + 1):
        try:
            async with async_session_maker() as session:
                # 只统计“最近 timeout_minutes 分钟内”的处理中记录；
                # 更早期的 processing 记录视为僵尸，不再阻塞账号。
                # 时间比较放在数据库侧完成，避免应用与数据库时区不一致。
                has_processing = bool(
                    (
                        await session.execute(
                            select(
                                exists().where(
                                    XYRiskControlLog.account_identifier
                                    == clean_identifier,
                                    XYRiskControlLog.processing_status == "processing",
                                    XYRiskControlLog.created_at
                                    >= func.date_sub(
                                        func.now(),
                                        text(f"INTERVAL {timeout_minutes} MINUTE"),
                                    ),
                                )
                            )
                        )
                    ).scalar()
                )
            return ProcessingRiskControlCheckResult(
                True,
                has_processing,
                (
                    "账号已有处理中的风控任务"
                    if has_processing
                    else "账号当前没有处理中的风控任务"
                ),
            )
        except Exception as exc:
            last_error = f"{type(exc).__name__}: {exc}"
            if attempt < attempts:
                await asyncio.sleep(max(0.0, retry_delay_seconds))

    return ProcessingRiskControlCheckResult(
        False,
        True,
        f"查询处理中风控日志失败，已重试{attempts}次：{last_error}",
    )
