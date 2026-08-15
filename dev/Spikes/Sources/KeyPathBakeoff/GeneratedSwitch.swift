extension FilterExpr where Root == Pane {
    package static func `where`<Value>(
        _ keyPath: KeyPath<Pane, Projected<Value>>,
        _ operation: FilterOperator<Value>
    ) throws(QueryConstructionError) -> Self {
        let field: FieldID
        switch keyPath as AnyKeyPath {
        case \Pane.command: field = .paneCommand
        case \Pane.title: field = .paneTitle
        case \Pane.width: field = .paneWidth
        case \Pane.alternateTitle: field = .paneAlternateTitle
        default: throw .unsupportedField
        }
        return Self(
            node: .predicate(
                model: .pane,
                field: field,
                operation: operation.operation
            )
        )
    }
}

extension FilterExpr where Root == PaneSession {
    package static func `where`(
        _ keyPath: KeyPath<PaneSession, Projected<String>>,
        _ operation: FilterOperator<String>
    ) throws(QueryConstructionError) -> Self {
        guard keyPath == \PaneSession.name else { throw .unsupportedField }
        return Self(
            node: .predicate(
                model: .paneSession,
                field: .paneSessionName,
                operation: operation.operation
            )
        )
    }
}

extension FilterExpr where Root == RelatedPane {
    package static func `where`(
        _ keyPath: KeyPath<RelatedPane, Projected<String>>,
        _ operation: FilterOperator<String>
    ) throws(QueryConstructionError) -> Self {
        guard keyPath == \RelatedPane.command else { throw .unsupportedField }
        return Self(
            node: .predicate(
                model: .relatedPane,
                field: .relatedPaneCommand,
                operation: operation.operation
            )
        )
    }
}

extension FilterExpr where Root == Pane {
    package static func `where`(
        _ keyPath: KeyPath<Pane, Projected<PaneSession?>>,
        _ operation: ToOneFilterOperator<PaneSession>
    ) throws(QueryConstructionError) -> Self {
        guard keyPath == \Pane.session else {
            throw .unsupportedRelation
        }
        return Self(
            node: .relation(
                model: .pane,
                relation: .paneSession,
                quantifier: .is,
                expression: operation.expression
            )
        )
    }
}

extension FilterExpr where Root == Pane {
    package static func `where`(
        _ keyPath: KeyPath<Pane, Projected<[RelatedPane]>>,
        _ operation: ToManyFilterOperator<RelatedPane>
    ) throws(QueryConstructionError) -> Self {
        guard keyPath == \Pane.relatedPanes else {
            throw .unsupportedRelation
        }
        return Self(
            node: .relation(
                model: .pane,
                relation: .paneRelatedPanes,
                quantifier: operation.quantifier,
                expression: operation.expression
            )
        )
    }
}

package func `where`(
    _ keyPath: KeyPath<Pane, Projected<String>>,
    _ operation: FilterOperator<String>
) throws(QueryConstructionError) -> FilterExpr<Pane> {
    try FilterExpr<Pane>.where(keyPath, operation)
}
