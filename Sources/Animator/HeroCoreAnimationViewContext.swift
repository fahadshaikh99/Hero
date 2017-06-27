// The MIT License (MIT)
//
// Copyright (c) 2016 Luke Zhao <me@lkzhao.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import UIKit

extension CALayer {
  internal static var heroAddedAnimations: [(CALayer, String, CAAnimation)]? = {
    let swizzling: (AnyClass, Selector, Selector) -> Void = { forClass, originalSelector, swizzledSelector in
      let originalMethod = class_getInstanceMethod(forClass, originalSelector)
      let swizzledMethod = class_getInstanceMethod(forClass, swizzledSelector)
      method_exchangeImplementations(originalMethod, swizzledMethod)
    }
    let originalSelector = #selector(add(_:forKey:))
    let swizzledSelector = #selector(hero_add(anim:forKey:))
    swizzling(CALayer.self, originalSelector, swizzledSelector)
    return nil
  }()

  @objc dynamic func hero_add(anim: CAAnimation, forKey: String?) {
    CALayer.heroAddedAnimations?.append((self, forKey!, anim))
    hero_add(anim: anim, forKey: forKey)
  }
}

internal class HeroCoreAnimationViewContext: HeroAnimatorViewContext {

  var state = [String: (Any?, Any?)]()
  var timingFunction: CAMediaTimingFunction = .standard

  var animations: [(CALayer, String, CAAnimation)] = []

  // computed
  var contentLayer: CALayer? {
    return snapshot.layer.sublayers?.get(0)
  }
  var overlayLayer: CALayer?

  override class func canAnimate(view: UIView, state: HeroTargetState, appearing: Bool) -> Bool {
    return state.position != nil ||
           state.size != nil ||
           state.transform != nil ||
           state.cornerRadius != nil ||
           state.opacity != nil ||
           state.overlay != nil ||
           state.backgroundColor != nil ||
           state.borderColor != nil ||
           state.borderWidth != nil ||
           state.shadowOpacity != nil ||
           state.shadowRadius != nil ||
           state.shadowOffset != nil ||
           state.shadowColor != nil ||
           state.shadowPath != nil ||
           state.contentsRect != nil ||
           state.forceAnimate
  }

  func getOverlayLayer() -> CALayer {
    if overlayLayer == nil {
      overlayLayer = CALayer()
      overlayLayer!.frame = snapshot.bounds
      overlayLayer!.opacity = 0
      snapshot.layer.addSublayer(overlayLayer!)
    }
    return overlayLayer!
  }

  func overlayKeyFor(key: String) -> String? {
    if key.hasPrefix("overlay.") {
      var key = key
      key.removeSubrange(key.startIndex..<key.index(key.startIndex, offsetBy: 8))
      return key
    }
    return nil
  }

  func currentValue(key: String) -> Any? {
    if let key = overlayKeyFor(key: key) {
      return overlayLayer?.value(forKeyPath: key)
    }
    if snapshot.layer.animationKeys()?.isEmpty != false {
      return snapshot.layer.value(forKeyPath:key)
    }
    return (snapshot.layer.presentation() ?? snapshot.layer).value(forKeyPath: key)
  }

  func getAnimation(key: String, beginTime: TimeInterval, duration: TimeInterval, fromValue: Any?, toValue: Any?, ignoreArc: Bool = false) -> CAPropertyAnimation {
    let key = overlayKeyFor(key: key) ?? key
    let anim: CAPropertyAnimation

    if !ignoreArc, key == "position", let arcIntensity = targetState.arc,
      let fromPos = (fromValue as? NSValue)?.cgPointValue,
      let toPos = (toValue as? NSValue)?.cgPointValue,
      abs(fromPos.x - toPos.x) >= 1, abs(fromPos.y - toPos.y) >= 1 {
      let kanim = CAKeyframeAnimation(keyPath: key)

      let path = CGMutablePath()
      let maxControl = fromPos.y > toPos.y ? CGPoint(x: toPos.x, y: fromPos.y) : CGPoint(x: fromPos.x, y: toPos.y)
      let minControl = (toPos - fromPos) / 2 + fromPos

      path.move(to: fromPos)
      path.addQuadCurve(to: toPos, control: minControl + (maxControl - minControl) * arcIntensity)

      kanim.values = [fromValue!, toValue!]
      kanim.path = path
      kanim.duration = duration
      kanim.timingFunctions = [timingFunction]
      anim = kanim
    } else if #available(iOS 9.0, *), key != "cornerRadius", let (stiffness, damping) = targetState.spring {
      let sanim = CASpringAnimation(keyPath: key)
      sanim.stiffness = stiffness
      sanim.damping = damping
      sanim.duration = sanim.settlingDuration
      sanim.fromValue = fromValue
      sanim.toValue = toValue
      anim = sanim
    } else {
      let banim = CABasicAnimation(keyPath: key)
      banim.duration = duration
      banim.fromValue = fromValue
      banim.toValue = toValue
      banim.timingFunction = timingFunction
      anim = banim
    }

    anim.fillMode = kCAFillModeBoth
    anim.isRemovedOnCompletion = false
    anim.beginTime = beginTime
    return anim
  }

  func setSize(view: UIView, newSize: CGSize) {
    let oldSize = view.bounds.size
    if targetState.snapshotType != .noSnapshot {
      for subview in view.subviews {
        let center = subview.center
        let size = subview.bounds.size
        subview.center = CGPoint(x: center.x / oldSize.width * newSize.width, y: center.y / oldSize.height * newSize.height)
        subview.bounds.size = size / oldSize * newSize
        setSize(view: subview, newSize: size / oldSize * newSize)
      }
      view.bounds.size = newSize
    } else {
      view.bounds.size = newSize
      view.layoutSubviews()
    }
  }

  func uiViewBasedAnimate(duration: TimeInterval, delay: TimeInterval, _ animations: @escaping () -> Void) {
    CATransaction.begin()
    if let (stiffness, damping) = targetState.spring {
      let fakeDamping = damping / (stiffness / 7.5)
      UIView.animate(withDuration: duration, delay: delay, usingSpringWithDamping: fakeDamping, initialSpringVelocity: 0, options: [.beginFromCurrentState], animations: animations, completion: nil)
    } else {
      CATransaction.setAnimationDuration(duration)
      CATransaction.setAnimationTimingFunction(timingFunction)
      UIView.animate(withDuration: duration, delay: delay, options: [.beginFromCurrentState], animations: animations, completion: nil)
    }
    CATransaction.commit()
  }

  // return the completion duration of the animation (duration + initial delay, not counting the beginTime)
  func animate(key: String, beginTime: TimeInterval, duration: TimeInterval, fromValue: Any?, toValue: Any?) -> TimeInterval {
    let anim = getAnimation(key: key, beginTime: beginTime, duration: duration, fromValue: fromValue, toValue: toValue)

    if let overlayKey = overlayKeyFor(key:key) {
      getOverlayLayer().add(anim, forKey: overlayKey)
    } else {
      switch key {
      case "cornerRadius", "contentsRect", "contentsScale":
        snapshot.layer.add(anim, forKey: key)
        contentLayer?.add(anim, forKey: key)
        overlayLayer?.add(anim, forKey: key)
      case "bounds.size":
        let fromSize = (fromValue as? NSValue)!.cgSizeValue
        let toSize = (toValue as? NSValue)!.cgSizeValue

        setSize(view: snapshot, newSize: fromSize)
        uiViewBasedAnimate(duration: anim.duration, delay: beginTime - currentTime) {
          self.setSize(view: self.snapshot, newSize: toSize)
        }
      default:
        snapshot.layer.add(anim, forKey: key)
      }
    }

    return anim.duration + anim.beginTime - beginTime
  }

  /**
   - Returns: a CALayer [keyPath:value] map for animation
   */
  func viewState(targetState: HeroTargetState) -> [String: Any?] {
    var targetState = targetState
    var rtn = [String: Any?]()

    if let size = targetState.size {
      if targetState.useScaleBasedSizeChange ?? self.targetState.useScaleBasedSizeChange ?? false {
        let currentSize = snapshot.bounds.size
        targetState.append(.scale(x:size.width / currentSize.width,
                                  y:size.height / currentSize.height))
      } else {
        rtn["bounds.size"] = NSValue(cgSize:size)
      }
    }
    if let position = targetState.position {
      rtn["position"] = NSValue(cgPoint:position)
    }
    if let opacity = targetState.opacity, !(snapshot is UIVisualEffectView) {
      rtn["opacity"] = NSNumber(value: opacity)
    }
    if let cornerRadius = targetState.cornerRadius {
      rtn["cornerRadius"] = NSNumber(value: cornerRadius.native)
    }
    if let backgroundColor = targetState.backgroundColor {
      rtn["backgroundColor"] = backgroundColor
    }
    if let zPosition = targetState.zPosition {
      rtn["zPosition"] = NSNumber(value: zPosition.native)
    }

    if let borderWidth = targetState.borderWidth {
      rtn["borderWidth"] = NSNumber(value: borderWidth.native)
    }
    if let borderColor = targetState.borderColor {
      rtn["borderColor"] = borderColor
    }
    if let masksToBounds = targetState.masksToBounds {
      rtn["masksToBounds"] = masksToBounds
    }

    if targetState.displayShadow {
      if let shadowColor = targetState.shadowColor {
        rtn["shadowColor"] = shadowColor
      }
      if let shadowRadius = targetState.shadowRadius {
        rtn["shadowRadius"] = NSNumber(value: shadowRadius.native)
      }
      if let shadowOpacity = targetState.shadowOpacity {
        rtn["shadowOpacity"] = NSNumber(value: shadowOpacity)
      }
      if let shadowPath = targetState.shadowPath {
        rtn["shadowPath"] = shadowPath
      }
      if let shadowOffset = targetState.shadowOffset {
        rtn["shadowOffset"] = NSValue(cgSize: shadowOffset)
      }
    }

    if let contentsRect = targetState.contentsRect {
      rtn["contentsRect"] = NSValue(cgRect: contentsRect)
    }

    if let contentsScale = targetState.contentsScale {
      rtn["contentsScale"] = NSNumber(value: contentsScale.native)
    }

    if let transform = targetState.transform {
      rtn["transform"] = NSValue(caTransform3D: transform)
    }

    if let (color, opacity) = targetState.overlay {
      rtn["overlay.backgroundColor"] = color
      rtn["overlay.opacity"] = NSNumber(value: opacity.native)
    }
    return rtn
  }

  override func apply(state: HeroTargetState) {
    let targetState = viewState(targetState: state)
    for (key, targetValue) in targetState {
      if self.state[key] == nil {
        let current = currentValue(key: key)
        self.state[key] = (current, current)
      }
      _ = animate(key: key, beginTime: 0, duration: 100, fromValue: targetValue, toValue: targetValue)
    }
  }

  override func resume(timePassed: TimeInterval, reverse: Bool) {
    for (key, (fromValue, toValue)) in state {
      let realToValue = !reverse ? toValue : fromValue
      let realFromValue = currentValue(key: key)
      state[key] = (realFromValue, realToValue)
    }

    if reverse {
      if timePassed > targetState.delay + duration {
        let backDelay = timePassed - (targetState.delay + duration)
        animate(beginTime: currentTime + backDelay, duration: duration)
      } else if timePassed > targetState.delay {
        animate(beginTime: currentTime, duration: duration - (timePassed - targetState.delay))
      }
    } else {
      if timePassed <= targetState.delay {
        animate(beginTime: currentTime + targetState.delay - timePassed, duration: duration)
      } else if timePassed <= targetState.delay + duration {
        let timePassedDelay = timePassed - targetState.delay
        animate(beginTime: currentTime, duration: duration - timePassedDelay)
      }
    }
  }

  func animate(beginTime: TimeInterval, duration: TimeInterval) {
    for (layer, key, _) in animations {
      layer.removeAnimation(forKey: key)
    }

    if let tf = targetState.timingFunction {
      timingFunction = tf
    }

    var timeUntilStop: TimeInterval = duration

    CALayer.heroAddedAnimations = []
    for (key, (fromValue, toValue)) in state {
      let neededTime = animate(key: key, beginTime: beginTime, duration: duration, fromValue: fromValue, toValue: toValue)
      timeUntilStop = max(timeUntilStop, neededTime)
    }
    animations = CALayer.heroAddedAnimations!
    CALayer.heroAddedAnimations = nil

    self.duration = timeUntilStop + beginTime - currentTime
  }

  func seek(layer: CALayer, timePassed: TimeInterval) {
    let timeOffset = timePassed - targetState.delay
    for (key, anim) in layer.animations {
      anim.speed = 0
      anim.timeOffset = max(0, min(anim.duration - 0.01, timeOffset))
      layer.removeAnimation(forKey: key)
      layer.add(anim, forKey: key)
    }
  }

  override func seek(timePassed: TimeInterval) {
    let timeOffset = timePassed - targetState.delay
    for (layer, key, anim) in animations {
      anim.speed = 0
      anim.timeOffset = max(0, min(anim.duration - 0.01, timeOffset))
      layer.removeAnimation(forKey: key)
      layer.add(anim, forKey: key)
    }
  }

  override func clean() {
    super.clean()
    overlayLayer = nil
  }

  override func startAnimations() {
    if let beginStateModifiers = targetState.beginState {
      let beginState = HeroTargetState(modifiers: beginStateModifiers)
      let appeared = viewState(targetState: beginState)
      for (key, value) in appeared {
        snapshot.layer.setValue(value, forKeyPath: key)
      }
      if let (color, opacity) = beginState.overlay {
        let overlay = getOverlayLayer()
        overlay.backgroundColor = color
        overlay.opacity = Float(opacity)
      }
    }

    let disappeared = viewState(targetState: targetState)

    for (key, disappearedState) in disappeared {
      let appearingState = currentValue(key: key)
      let toValue = appearing ? appearingState : disappearedState
      let fromValue = !appearing ? appearingState : disappearedState
      state[key] = (fromValue, toValue)
    }

    animate(beginTime: currentTime + targetState.delay, duration: duration)
  }
}
