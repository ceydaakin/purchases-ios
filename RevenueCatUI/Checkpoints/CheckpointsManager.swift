//
//  Copyright RevenueCat Inc. All Rights Reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://opensource.org/licenses/MIT
//
//  CheckpointsManager.swift
//
//  Created by Rick van der Linden.
//

import Foundation
@_spi(Internal) import RevenueCat

/// Orchestrates checkpoint resolution and workflow execution.
@MainActor
@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
final class CheckpointsManager {

    typealias CustomerInfoSynchronizer = @MainActor () async throws -> CustomerInfo
    typealias CachedCustomerInfoProvider = @MainActor () -> CustomerInfo?

    private let resolveCheckpoint: (String, CheckpointCallParams) async throws -> CheckpointResolution
    private let cachedCustomerInfoProvider: CachedCustomerInfoProvider
    private let checkpointPresenter: CheckpointPresenterType
    var paywallPresenter: PaywallPresenter?
    var errorPresenter: ErrorPresenter?

    init(
        resolveCheckpoint: @escaping (String, CheckpointCallParams) async throws -> CheckpointResolution,
        checkpointPresenter: CheckpointPresenterType? = nil,
        cachedCustomerInfoProvider: @escaping CachedCustomerInfoProvider = { nil },
        customerInfoSynchronizer: @escaping CustomerInfoSynchronizer = { throw CancellationError() }
    ) {
        self.resolveCheckpoint = resolveCheckpoint
        self.cachedCustomerInfoProvider = cachedCustomerInfoProvider
        self.checkpointPresenter = checkpointPresenter ?? CheckpointPresenter(
            workflowPresenter: WorkflowPresenter(),
            cachedCustomerInfoProvider: cachedCustomerInfoProvider,
            customerInfoSynchronizer: customerInfoSynchronizer
        )
    }

    func setPaywallPresenter(_ presenter: PaywallPresenter?) {
        self.paywallPresenter = presenter
    }

    func setErrorPresenter(_ presenter: ErrorPresenter?) {
        self.errorPresenter = presenter
    }

    func errorPresentationHandler(
        for params: CheckpointCallParams,
        defaultHandler makeDefaultHandler: () -> ErrorPresentationHandler
    ) -> ErrorPresentationHandler {
        if let localHandler = params.localErrorPresentationHandler {
            return localHandler
        }

        if let globalPresenter = self.errorPresenter {
            return { params, completion in
                globalPresenter.present(params: params, completion: completion)
            }
        }

        return makeDefaultHandler()
    }

    func executeCheckpoint(
        identifier: String,
        params: CheckpointCallParams
    ) async throws -> CheckpointPresentationOutcome {
        return try await self.executeCheckpointWithContext(identifier: identifier, params: params).outcome
    }

    private func executeCheckpointWithContext(
        identifier: String,
        params: CheckpointCallParams
    ) async throws -> CheckpointExecutionResult {
        let globalPaywallPresenter = self.paywallPresenter
        let errorPresentationHandler = self.errorPresentationHandler(
            for: params,
            defaultHandler: {
                let presenter = DefaultErrorPresenter()
                return { params, completion in
                    presenter.present(params: params, completion: completion)
                }
            }
        )

        guard CheckpointIdentifierValidator.isValid(identifier) else {
            Logger.error(CheckpointIdentifierValidator.invalidIdentifierLogMessage(identifier))
            return .init(outcome: .nothingPresented)
        }

        switch try await self.resolveCheckpoint(identifier, params) {
        case let .matchedWorkflow(workflow):
            let presentation = WorkflowPresentationRequest(
                checkpointIdentifier: identifier,
                workflow: workflow,
                customVariables: params.customVariables,
                presentationMode: params.presentationMode,
                initialActiveEntitlementIdentifiers: self.initialActiveEntitlementIdentifiers(),
                errorPresentationHandler: errorPresentationHandler
            )
            return .init(
                outcome: try await self.checkpointPresenter.presentWorkflow(presentation),
                availableProducts: workflow.offerings.all.values.flatMap(\.availablePackages).map(\.storeProduct)
            )
        case let .matchedOffering(offering):
            return .init(
                outcome: try await self.checkpointPresenter.presentOffering(
                    params: .init(
                        checkpointIdentifier: identifier,
                        customVariables: params.customVariables,
                        presentationMode: params.presentationMode,
                        offering: offering,
                        errorPresentationHandler: errorPresentationHandler
                    ),
                    globalPaywallPresenter: globalPaywallPresenter,
                    localPaywallPresentationHandler: params.localPaywallPresentationHandler
                ),
                availableProducts: offering.availablePackages.map(\.storeProduct)
            )
        case .noAction:
            return .init(outcome: .nothingPresented)
        }
    }

    func checkpointForCallback(
        identifier: String,
        params: CheckpointCallParams
    ) async -> CheckpointCallbackResult {
        let initialCustomerInfo = self.cachedCustomerInfoProvider()
        let initialActiveEntitlementIdentifiers = initialCustomerInfo.map { Set($0.entitlements.active.keys) }

        do {
            let execution = try await self.executeCheckpointWithContext(identifier: identifier, params: params)
            switch execution.outcome {
            case .backedOut:
                return .suppressed
            case let .completed(customerInfo):
                return .completed(CheckpointResult(
                    flow: self.flowResult(
                        customerInfo: customerInfo,
                        initialCustomerInfo: initialCustomerInfo,
                        initialActiveEntitlementIdentifiers: initialActiveEntitlementIdentifiers,
                        availableProducts: execution.availableProducts
                    ),
                    customer: customerInfo
                ))
            case .failed, .nothingPresented:
                return .completed(CheckpointResult(flow: nil, customer: nil))
            }
        } catch CheckpointError.operationAlreadyInProgress {
            return .suppressed
        } catch {
            return .completed(CheckpointResult(flow: nil, customer: nil))
        }
    }

    private func flowResult(
        customerInfo: CustomerInfo?,
        initialCustomerInfo: CustomerInfo?,
        initialActiveEntitlementIdentifiers: Set<String>?,
        availableProducts: [StoreProduct]
    ) -> FlowResult {
        let obtainedEntitlements = customerInfo?
            .obtainedEntitlements(comparedTo: initialActiveEntitlementIdentifiers)
            .map(ObtainedEntitlement.init)
            ?? []
        let obtainedProducts = customerInfo?
            .obtainedProducts(comparedTo: initialCustomerInfo, from: availableProducts)
            ?? []

        return FlowResult(
            obtainedEntitlements: Set(obtainedEntitlements),
            obtainedProducts: Set(obtainedProducts)
        )
    }

    private func initialActiveEntitlementIdentifiers() -> Set<String>? {
        return self.cachedCustomerInfoProvider().map { customerInfo in
            Set(customerInfo.entitlements.active.keys)
        }
    }

}

@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
private struct CheckpointExecutionResult {

    let outcome: CheckpointPresentationOutcome
    let availableProducts: [StoreProduct]

    init(outcome: CheckpointPresentationOutcome, availableProducts: [StoreProduct] = []) {
        self.outcome = outcome
        self.availableProducts = availableProducts
    }

}

@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
enum CheckpointCallbackResult {
    case completed(CheckpointResult)
    case suppressed
}
