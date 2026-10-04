//
//  Lock.swift
//  yina
//
//  Created by low-batt on 9/5/22.
//  Copyright © 2022 lhc. All rights reserved.
//

import Foundation

/// An object that coordinates the operation of multiple threads of execution.
///
/// The underlying unfair lock has stable heap storage and is never copied.
///
///- Warning: This isn’t a recursive lock. Attempting to lock an object more than once from the same thread without unlocking in
///    between will trigger a runtime exception.
class Lock {

  private let lock = OSUnfairLockImpl()

  /// Executes a closure while holding a lock.
  /// - Parameter body: A closure that contains the code to execute using the lock.
  /// - Returns: The value that body returns.
  /// - Throws: The exception that body throws.
  func withLock<R>(_ body: () throws -> R) rethrows -> R {
    return try lock.withLock(body)
  }
}

// MARK: - Implementation

private class OSUnfairLockImpl {

  // Use a pointer to ensure the lock, which is a struct, is not copied.
  private let lock = os_unfair_lock_t.allocate(capacity: 1)

  init() {
    lock.initialize(to: .init())
  }

  deinit {
    lock.deinitialize(count: 1)
    lock.deallocate()
  }

  func withLock<R>(_ body: () throws -> R) rethrows -> R {
    os_unfair_lock_lock(lock)
    defer { os_unfair_lock_unlock(lock) }
    return try body()
  }
}
