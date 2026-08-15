package enum ErasedMapLowering {
    package static func `where`(
        _ keyPath: KeyPath<Pane, Projected<String>>,
        _ operation: FilterOperator<String>
    ) throws(QueryConstructionError) -> FilterExpr<Pane> {
        let fields: [AnyKeyPath: FieldID] = [
            \Pane.command: .paneCommand,
            \Pane.title: .paneTitle,
        ]
        guard let field = fields[keyPath] else { throw .unsupportedField }
        return lowered(model: .pane, field: field, operation: operation)
    }

    package static func `where`(
        _ keyPath: KeyPath<Pane, Projected<Int>>,
        _ operation: FilterOperator<Int>
    ) throws(QueryConstructionError) -> FilterExpr<Pane> {
        let fields: [AnyKeyPath: FieldID] = [\Pane.width: .paneWidth]
        guard let field = fields[keyPath] else { throw .unsupportedField }
        return lowered(model: .pane, field: field, operation: operation)
    }

    package static func `where`(
        _ keyPath: KeyPath<Pane, Projected<String?>>,
        _ operation: FilterOperator<String?>
    ) throws(QueryConstructionError) -> FilterExpr<Pane> {
        let fields: [AnyKeyPath: FieldID] = [
            \Pane.alternateTitle: .paneAlternateTitle
        ]
        guard let field = fields[keyPath] else { throw .unsupportedField }
        return lowered(model: .pane, field: field, operation: operation)
    }

    package static func `where`(
        _ keyPath: KeyPath<PaneSession, Projected<String>>,
        _ operation: FilterOperator<String>
    ) throws(QueryConstructionError) -> FilterExpr<PaneSession> {
        let fields: [AnyKeyPath: FieldID] = [
            \PaneSession.name: .paneSessionName
        ]
        guard let field = fields[keyPath] else { throw .unsupportedField }
        return lowered(model: .paneSession, field: field, operation: operation)
    }

    package static func `where`(
        _ keyPath: KeyPath<RelatedPane, Projected<String>>,
        _ operation: FilterOperator<String>
    ) throws(QueryConstructionError) -> FilterExpr<RelatedPane> {
        let fields: [AnyKeyPath: FieldID] = [
            \RelatedPane.command: .relatedPaneCommand
        ]
        guard let field = fields[keyPath] else { throw .unsupportedField }
        return lowered(model: .relatedPane, field: field, operation: operation)
    }

    package static func `where`(
        _ keyPath: KeyPath<Pane, Projected<PaneSession?>>,
        _ operation: ToOneFilterOperator<PaneSession>
    ) throws(QueryConstructionError) -> FilterExpr<Pane> {
        let relations: [AnyKeyPath: RelationID] = [
            \Pane.session: .paneSession
        ]
        guard let relation = relations[keyPath] else { throw .unsupportedRelation }
        return FilterExpr(
            node: .relation(
                model: .pane,
                relation: relation,
                quantifier: .is,
                expression: operation.expression
            )
        )
    }

    package static func `where`(
        _ keyPath: KeyPath<Pane, Projected<[RelatedPane]>>,
        _ operation: ToManyFilterOperator<RelatedPane>
    ) throws(QueryConstructionError) -> FilterExpr<Pane> {
        let relations: [AnyKeyPath: RelationID] = [
            \Pane.relatedPanes: .paneRelatedPanes
        ]
        guard let relation = relations[keyPath] else { throw .unsupportedRelation }
        return FilterExpr(
            node: .relation(
                model: .pane,
                relation: relation,
                quantifier: operation.quantifier,
                expression: operation.expression
            )
        )
    }

    private static func lowered<Root: QueryRoot, Value>(
        model: ModelID,
        field: FieldID,
        operation: FilterOperator<Value>
    ) -> FilterExpr<Root> {
        FilterExpr(
            node: .predicate(
                model: model,
                field: field,
                operation: operation.operation
            )
        )
    }
}
