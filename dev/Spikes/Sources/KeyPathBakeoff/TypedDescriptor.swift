package struct FieldDescriptor<Root: QueryRoot, Value>: Hashable, Sendable {
    package let model: ModelID
    package let field: FieldID

    package init(model: ModelID, field: FieldID) {
        self.model = model
        self.field = field
    }
}

package struct ToOneRelationDescriptor<Root: QueryRoot, Related: QueryRoot>: Hashable, Sendable {
    package let model: ModelID
    package let relation: RelationID

    package init(model: ModelID, relation: RelationID) {
        self.model = model
        self.relation = relation
    }
}

package struct ToManyRelationDescriptor<Root: QueryRoot, Related: QueryRoot>: Hashable, Sendable {
    package let model: ModelID
    package let relation: RelationID

    package init(model: ModelID, relation: RelationID) {
        self.model = model
        self.relation = relation
    }
}

package enum PaneFields {
    package static let command = FieldDescriptor<Pane, String>(
        model: .pane,
        field: .paneCommand
    )
    package static let title = FieldDescriptor<Pane, String>(
        model: .pane,
        field: .paneTitle
    )
    package static let width = FieldDescriptor<Pane, Int>(
        model: .pane,
        field: .paneWidth
    )
    package static let alternateTitle = FieldDescriptor<Pane, String?>(
        model: .pane,
        field: .paneAlternateTitle
    )
}

package enum PaneRelations {
    package static let session = ToOneRelationDescriptor<Pane, PaneSession>(
        model: .pane,
        relation: .paneSession
    )
    package static let relatedPanes = ToManyRelationDescriptor<Pane, RelatedPane>(
        model: .pane,
        relation: .paneRelatedPanes
    )
}

package enum PaneSessionFields {
    package static let name = FieldDescriptor<PaneSession, String>(
        model: .paneSession,
        field: .paneSessionName
    )
}

package enum RelatedPaneFields {
    package static let command = FieldDescriptor<RelatedPane, String>(
        model: .relatedPane,
        field: .relatedPaneCommand
    )
}

package enum TypedDescriptorLowering {
    package static func `where`<Root: QueryRoot, Value>(
        _ descriptor: FieldDescriptor<Root, Value>,
        _ operation: FilterOperator<Value>
    ) -> FilterExpr<Root> {
        FilterExpr(
            node: .predicate(
                model: descriptor.model,
                field: descriptor.field,
                operation: operation.operation
            )
        )
    }

    package static func `where`<Root: QueryRoot, Related: QueryRoot>(
        _ descriptor: ToOneRelationDescriptor<Root, Related>,
        _ operation: ToOneFilterOperator<Related>
    ) -> FilterExpr<Root> {
        FilterExpr(
            node: .relation(
                model: descriptor.model,
                relation: descriptor.relation,
                quantifier: .is,
                expression: operation.expression
            )
        )
    }

    package static func `where`<Root: QueryRoot, Related: QueryRoot>(
        _ descriptor: ToManyRelationDescriptor<Root, Related>,
        _ operation: ToManyFilterOperator<Related>
    ) -> FilterExpr<Root> {
        FilterExpr(
            node: .relation(
                model: descriptor.model,
                relation: descriptor.relation,
                quantifier: operation.quantifier,
                expression: operation.expression
            )
        )
    }
}
