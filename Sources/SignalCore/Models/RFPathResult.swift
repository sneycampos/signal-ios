import Foundation
import simd

public struct RFWallCrossing: Equatable, Sendable {
    public let wall: RFWallSegment
    public let point: SIMD2<Float>
    public let loss: Float
    public let cosTheta: Float
    
    public init(wall: RFWallSegment, point: SIMD2<Float>, loss: Float, cosTheta: Float) {
        self.wall = wall
        self.point = point
        self.loss = loss
        self.cosTheta = cosTheta
    }
}

public struct RFDirectPathResult: Equatable, Sendable {
    public let directRSSI: Float
    public let fspl: Float
    public let dist: Float
    public let crossingLossTotal: Float
    public let crossings: [RFWallCrossing]
    
    public init(
        directRSSI: Float,
        fspl: Float,
        dist: Float,
        crossingLossTotal: Float,
        crossings: [RFWallCrossing]
    ) {
        self.directRSSI = directRSSI
        self.fspl = fspl
        self.dist = dist
        self.crossingLossTotal = crossingLossTotal
        self.crossings = crossings
    }
}

public struct RFReflectionPath: Equatable, Sendable {
    public let reflectWall: RFWallSegment
    public let reflPoint: SIMD2<Float>
    public let pathRSSI: Float
    public let unfoldDist: Float
    public let legLoss: Float
    
    public init(
        reflectWall: RFWallSegment,
        reflPoint: SIMD2<Float>,
        pathRSSI: Float,
        unfoldDist: Float,
        legLoss: Float
    ) {
        self.reflectWall = reflectWall
        self.reflPoint = reflPoint
        self.pathRSSI = pathRSSI
        self.unfoldDist = unfoldDist
        self.legLoss = legLoss
    }
}
